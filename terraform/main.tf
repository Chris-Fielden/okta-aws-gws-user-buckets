data "aws_caller_identity" "current" {}
data "aws_ssoadmin_instances" "this" {}

# ---------------------------------------------------------------------------
# 1. Okta: active owners and offboarded owners
# ---------------------------------------------------------------------------
data "okta_group" "eligible" {
  name          = var.okta_group_name
  include_users = true
}

data "okta_group" "offboarded" {
  name          = var.okta_offboarded_group_name
  include_users = true
}

locals {
  offboarded_ids = toset(data.okta_group.offboarded.users)
  owner_ids      = setunion(toset(data.okta_group.eligible.users), local.offboarded_ids)
}

# Owners (still readable by ID after deactivation)
data "okta_user" "owner" {
  for_each = local.owner_ids
  user_id  = each.value
}

# ---------------------------------------------------------------------------
# 2. Resolve owner -> delegate via var.manager, walking up the chain
# ---------------------------------------------------------------------------
locals {
  instance_arn      = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  account_id        = data.aws_caller_identity.current.account_id

  manager_map = { for k, v in var.manager : lower(k) => lower(v) }
  fallback    = var.fallback_delegate_email == null ? null : lower(var.fallback_delegate_email)

  # Owner facts. Names derive from the OWNER so they never change on offboarding.
  owners = {
    for id, u in data.okta_user.owner : id => {
      okta_id    = id
      email      = lower(u.email)
      login      = lower(u.login)
      slug       = replace(lower(split("@", u.email)[0]), "/[^a-z0-9-]/", "-")
      hash       = substr(md5(lower(u.email)), 0, 8)
      offboarded = contains(local.offboarded_ids, id)
    }
  }

  # Anyone already offboarded cannot inherit from someone else.
  offboarded_emails = toset([for o in local.owners : o.email if o.offboarded])

  # Management chain, 5 levels ("" = no further manager). Extend by adding chain_6...
  chain_1 = { for id, o in local.owners : id => lookup(local.manager_map, o.email, "") }
  chain_2 = { for id, m in local.chain_1 : id => m == "" ? "" : lookup(local.manager_map, m, "") }
  chain_3 = { for id, m in local.chain_2 : id => m == "" ? "" : lookup(local.manager_map, m, "") }
  chain_4 = { for id, m in local.chain_3 : id => m == "" ? "" : lookup(local.manager_map, m, "") }
  chain_5 = { for id, m in local.chain_4 : id => m == "" ? "" : lookup(local.manager_map, m, "") }

  chain = {
    for id, o in local.owners : id => compact([
      local.chain_1[id], local.chain_2[id], local.chain_3[id], local.chain_4[id], local.chain_5[id],
    ])
  }

  # First chain member who is not offboarded and not the owner (guards against cycles); else fallback.
  delegate_email = {
    for id, o in local.owners : id => try(
      [for c in local.chain[id] : c if !contains(local.offboarded_emails, c) && c != o.email][0],
      local.fallback
    )
  }

  # Effective recipient: owner while active; delegate once offboarded.
  # NOTE: the delegate's Identity Center userName is assumed to equal their email.
  users = {
    for id, o in local.owners : id => merge(o, {
      delegate_email  = local.delegate_email[id]
      delegate_source = !o.offboarded ? "owner" : (local.delegate_email[id] == null ? "none" : (local.delegate_email[id] == local.fallback ? "fallback" : "manager-chain"))
      effective_email = o.offboarded ? local.delegate_email[id] : o.email
      effective_login = o.offboarded ? local.delegate_email[id] : o.login

      bucket_name    = "${var.name_prefix}-${substr(o.slug, 0, 30)}-${o.hash}"
      topic_name     = "${var.name_prefix}-notify-${substr(o.slug, 0, 30)}-${o.hash}"
      permission_set = "${var.name_prefix}-${substr(o.slug, 0, 16)}-${o.hash}" # <= 32 chars
    })
  }
}

# ---------------------------------------------------------------------------
# 3. Google Workspace: confirm the effective recipient exists
# ---------------------------------------------------------------------------
data "googleworkspace_user" "this" {
  for_each      = local.users
  primary_email = each.value.effective_email

  lifecycle {
    precondition {
      condition     = each.value.effective_email != null
      error_message = "${each.value.email} is offboarded but no available delegate exists in var.manager (5 levels) and fallback_delegate_email is unset. Refusing to leave the bucket unowned."
    }
  }
}

# ---------------------------------------------------------------------------
# 4. Identity Center principal (SCIM from Okta) for the effective recipient
# ---------------------------------------------------------------------------
data "aws_identitystore_user" "principal" {
  for_each          = local.users
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = each.value.effective_login
    }
  }

  lifecycle {
    precondition {
      condition     = each.value.effective_login != null
      error_message = "No delegate login resolved for ${each.value.email}."
    }
  }
}

# ---------------------------------------------------------------------------
# 5. Per-user S3 bucket: retained across offboarding
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "user" {
  for_each      = local.users
  bucket        = each.value.bucket_name
  force_destroy = false

  tags = {
    Owner          = each.value.email
    OktaUserId     = each.value.okta_id
    LifecycleState = each.value.offboarded ? "offboarded" : "active"
    DelegatedTo    = each.value.offboarded ? each.value.effective_email : "none"
  }

  lifecycle {
    precondition {
      condition     = each.value.effective_email == null ? false : endswith(each.value.effective_email, "@${var.email_domain}")
      error_message = "Recipient ${coalesce(each.value.effective_email, "<none>")} is not in @${var.email_domain}; refusing to provision."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "user" {
  for_each                = local.users
  bucket                  = aws_s3_bucket.user[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "user" {
  for_each = local.users
  bucket   = aws_s3_bucket.user[each.key].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "user" {
  for_each = local.users
  bucket   = aws_s3_bucket.user[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "user" {
  for_each = local.users
  bucket   = aws_s3_bucket.user[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "bucket" {
  for_each = local.users

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.user[each.key].arn, "${aws_s3_bucket.user[each.key].arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "user" {
  for_each   = local.users
  bucket     = aws_s3_bucket.user[each.key].id
  policy     = data.aws_iam_policy_document.bucket[each.key].json
  depends_on = [aws_s3_bucket_public_access_block.user]
}

# ---------------------------------------------------------------------------
# 6. Permission set scoped to this bucket, assigned to the EFFECTIVE principal
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "user_access" {
  for_each = local.users

  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketVersions", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.user[each.key].arn]
  }

  statement {
    sid = "ReadWriteObjects"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.user[each.key].arn}/*"]
  }
}

resource "aws_ssoadmin_permission_set" "user" {
  for_each         = local.users
  name             = each.value.permission_set
  description      = "Access to ${each.value.bucket_name} (owner: ${each.value.email}; state: ${each.value.offboarded ? "offboarded" : "active"})"
  instance_arn     = local.instance_arn
  session_duration = var.session_duration
}

resource "aws_ssoadmin_permission_set_inline_policy" "user" {
  for_each           = local.users
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.user[each.key].arn
  inline_policy      = data.aws_iam_policy_document.user_access[each.key].json
}

resource "aws_ssoadmin_account_assignment" "user" {
  for_each           = local.users
  instance_arn       = local.instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.user[each.key].arn

  principal_id   = data.aws_identitystore_user.principal[each.key].user_id
  principal_type = "USER"

  target_id   = local.account_id
  target_type = "AWS_ACCOUNT"

  depends_on = [aws_ssoadmin_permission_set_inline_policy.user]
}

# ---------------------------------------------------------------------------
# 7. Notifications -> effective recipient's Google Workspace email
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "user" {
  for_each     = local.users
  name         = each.value.topic_name
  display_name = "S3 activity: ${each.value.bucket_name}"
}

# AWS requires the recipient to click a confirmation link; Terraform cannot do this.
resource "aws_sns_topic_subscription" "email" {
  for_each  = local.users
  topic_arn = aws_sns_topic.user[each.key].arn
  protocol  = "email"
  endpoint  = data.googleworkspace_user.this[each.key].primary_email
}

data "aws_iam_policy_document" "topic" {
  for_each = local.users

  statement {
    sid       = "AllowS3Publish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.user[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.user[each.key].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "AllowEventBridgePublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.user[each.key].arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.bucket_changes[each.key].arn]
    }
  }
}

resource "aws_sns_topic_policy" "user" {
  for_each = local.users
  arn      = aws_sns_topic.user[each.key].arn
  policy   = data.aws_iam_policy_document.topic[each.key].json
}

resource "aws_s3_bucket_notification" "user" {
  for_each = local.users
  bucket   = aws_s3_bucket.user[each.key].id

  topic {
    topic_arn = aws_sns_topic.user[each.key].arn
    events    = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
  }

  depends_on = [aws_sns_topic_policy.user]
}

resource "aws_cloudwatch_event_rule" "bucket_changes" {
  for_each    = local.users
  name        = "${each.value.topic_name}-cfg"
  description = "Configuration changes on ${each.value.bucket_name}"

  # Requires an existing CloudTrail trail capturing management events in this region.
  event_pattern = jsonencode({
    source        = ["aws.s3"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["s3.amazonaws.com"]
      eventName = [
        "PutBucketPolicy", "DeleteBucketPolicy",
        "PutBucketAcl",
        "PutBucketPublicAccessBlock", "DeletePublicAccessBlock",
        "PutBucketVersioning",
        "PutBucketEncryption", "DeleteBucketEncryption",
        "PutBucketOwnershipControls", "DeleteBucketOwnershipControls",
        "PutBucketLifecycle", "PutBucketLifecycleConfiguration", "DeleteBucketLifecycle",
        "PutBucketReplication", "DeleteBucketReplication",
        "PutBucketNotification", "PutBucketNotificationConfiguration",
        "PutBucketTagging", "DeleteBucketTagging",
        "PutBucketCors", "DeleteBucketCors",
        "DeleteBucket",
      ]
      requestParameters = {
        bucketName = [each.value.bucket_name]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "bucket_changes" {
  for_each  = local.users
  rule      = aws_cloudwatch_event_rule.bucket_changes[each.key].name
  target_id = "sns-email"
  arn       = aws_sns_topic.user[each.key].arn

  input_transformer {
    input_paths = {
      bucket = "$.detail.requestParameters.bucketName"
      event  = "$.detail.eventName"
      actor  = "$.detail.userIdentity.arn"
      ip     = "$.detail.sourceIPAddress"
      time   = "$.detail.eventTime"
    }
    input_template = "\"S3 bucket <bucket> changed: <event> by <actor> from <ip> at <time>\""
  }

  depends_on = [aws_sns_topic_policy.user]
}
