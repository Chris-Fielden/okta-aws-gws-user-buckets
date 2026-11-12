# Every value this system cannot know is a variable. Full write-ups: docs/VARIABLES.md.
# Variables without a default are REQUIRED.

# ----------------------------------------------------------------------------
# AWS
# ----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region where IAM Identity Center is enabled (its 'home region'). Buckets, SNS topics and EventBridge rules are created in this same region."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Short prefix on every per-user resource name (bucket, SNS topic, permission set). Lowercase letters/digits/hyphens, 2-15 chars. Pick something unique to your company so bucket names are globally unique."
  type        = string
  default     = "ub"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,14}$", var.name_prefix))
    error_message = "name_prefix must be 2-15 chars: lowercase letters, digits, hyphens; must start with a letter or digit."
  }
}

variable "session_duration" {
  description = "How long an Identity Center session for the per-user permission set lasts (ISO-8601 duration, 1h-12h), e.g. PT8H."
  type        = string
  default     = "PT8H"
}

variable "tags" {
  description = "Tags applied to every AWS resource via the provider's default_tags. Add cost-center / owner-team tags your organization requires."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Purpose   = "per-user-bucket"
  }
}

# ----------------------------------------------------------------------------
# Bucket behaviour
# ----------------------------------------------------------------------------
variable "bucket_force_destroy" {
  description = "If true, Terraform may delete a user's bucket even when it contains objects. Leave false: it makes final deletion of an offboarded user's bucket a deliberate, manual step."
  type        = bool
  default     = false
}

variable "bucket_noncurrent_version_expiration_days" {
  description = "Delete old object versions after this many days (cost control for versioned buckets). 0 disables the lifecycle rule and keeps every version forever."
  type        = number
  default     = 0

  validation {
    condition     = var.bucket_noncurrent_version_expiration_days >= 0
    error_message = "Must be 0 (disabled) or a positive number of days."
  }
}

# ----------------------------------------------------------------------------
# Notifications
# ----------------------------------------------------------------------------
variable "bucket_object_event_types" {
  description = "S3 object-level event types that email the bucket's current recipient. See the S3 event notification types list in AWS docs."
  type        = list(string)
  default     = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]

  validation {
    condition     = length(var.bucket_object_event_types) > 0
    error_message = "Provide at least one S3 event type (or set enable object events elsewhere)."
  }
}

variable "enable_config_change_notifications" {
  description = "If true, also email on bucket CONFIGURATION changes (policy, ACL, encryption, ...). Requires an existing CloudTrail trail recording management events in aws_region. If you have no trail, set false."
  type        = bool
  default     = true
}

variable "bucket_config_event_names" {
  description = "CloudTrail S3 API event names that count as a configuration change (only used when enable_config_change_notifications = true)."
  type        = list(string)
  default = [
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
}

# ----------------------------------------------------------------------------
# Okta
# ----------------------------------------------------------------------------
variable "okta_org_name" {
  description = "Okta org subdomain: the part before '.okta.com' in your Okta URL."
  type        = string
}

variable "okta_base_url" {
  description = "Okta base domain. 'okta.com' for production orgs, 'oktapreview.com' for preview orgs, 'okta-emea.com' for EMEA cells."
  type        = string
  default     = "okta.com"
}

variable "okta_group_name" {
  description = "Exact name of the Okta group whose members are ACTIVE bucket owners. Your eligibility automation adds users here after they pass your checks (docs/OKTA_WORKFLOWS.md, Flow 1)."
  type        = string
  default     = "aws-user-bucket-eligible"
}

variable "okta_offboarded_group_name" {
  description = "Exact name of the Okta group holding DEPARTED users who owned a bucket. Membership switches that user's bucket, AWS access and notifications to their delegate. Your offboarding automation adds users here (Flow 2/3)."
  type        = string
  default     = "aws-user-bucket-offboarded"
}

variable "okta_departed_group_name" {
  description = "Optional. Exact name of an Okta group holding EVERY departed employee (with or without a bucket). Used only to stop a departed manager from being chosen as a delegate. null disables the check (then only offboarded bucket owners count as unavailable)."
  type        = string
  default     = null
}

variable "scim_username_attribute" {
  description = "Which Okta attribute your SCIM app sends as the Identity Center userName for ACTIVE owners: 'email' or 'login'. Check one provisioned user in the Identity Center console."
  type        = string
  default     = "email"

  validation {
    condition     = contains(["email", "login"], var.scim_username_attribute)
    error_message = "scim_username_attribute must be 'email' or 'login'."
  }
}

variable "delegate_username_overrides" {
  description = "Only needed for delegates (managers/fallback) whose Identity Center userName differs from their email. Map of delegate email => Identity Center userName. Delegates default to using their email."
  type        = map(string)
  default     = {}
}

# ----------------------------------------------------------------------------
# Manager chain (who inherits when someone leaves)
# ----------------------------------------------------------------------------
variable "manager" {
  description = "Map of user email => that user's manager email. Walked up to 5 levels: a manager's own entry gives the next level. Keep it current; see docs/VARIABLES.md for the maintenance rules."
  type        = map(string)
  default     = {}
  # Shape (real addresses go in terraform.tfvars):
  #   { "<user email>" = "<that user's manager email>", ... }
}

variable "fallback_delegate_email" {
  description = "Last-resort recipient when nobody in a user's manager chain is available. Use a real, monitored account (e.g. an IT/security owner) that exists in Google Workspace and Identity Center. null = fail the plan instead of falling back."
  type        = string
  default     = null
}

# ----------------------------------------------------------------------------
# Google Workspace
# ----------------------------------------------------------------------------
variable "email_domain" {
  description = "Your Google Workspace primary domain WITHOUT the '@'. Every recipient email must end in it, otherwise the plan refuses to provision."
  type        = string

  validation {
    condition     = !startswith(var.email_domain, "@") && length(regexall("\\.", var.email_domain)) > 0
    error_message = "email_domain must be a bare domain such as your Workspace domain (no leading '@')."
  }
}

variable "gws_credentials_file" {
  description = "Filesystem path to the Google service account JSON key (domain-wide delegation enabled)."
  type        = string
  sensitive   = true
}

variable "gws_customer_id" {
  description = "Google Workspace customer ID (Admin console > Account > Account settings)."
  type        = string
}

variable "gws_impersonated_admin" {
  description = "Email of the Workspace admin the service account impersonates for directory reads."
  type        = string
}

variable "gws_oauth_scopes" {
  description = "OAuth scopes the Terraform Google provider requests. Read-only directory access is enough; widen only if the provider returns 403."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/admin.directory.user.readonly"]
}
