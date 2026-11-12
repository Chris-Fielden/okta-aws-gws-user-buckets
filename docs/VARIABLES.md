# Variables: what each one is, where to get it, what breaks if it is wrong

This repo assumes every value below is replaced with a real, defined value for **your** company.
Nothing in the repo is a real value; angle-bracket tokens like `<THIS>` are placeholders.

Four places hold variables:

1. [Terraform variables](#1-terraform-variables) (`terraform/variables.tf`, set in `terraform.tfvars`)
2. [Environment variables read by providers](#2-provider-environment-variables)
3. [GitHub secrets, variables and environments](#3-github-secrets-variables-and-environments)
4. [Script arguments](#4-transfer-script-arguments) and [Okta Workflows constants](OKTA_WORKFLOWS.md#3-workflows-constants-and-table)

---

## 1. Terraform variables

**Required** = no default; Terraform will not plan without it.

### AWS

| Variable | Required | Default |
|---|---|---|
| `aws_region` | no | `us-east-1` |
| `name_prefix` | no | `ub` |
| `session_duration` | no | `PT8H` |
| `tags` | no | `ManagedBy`, `Purpose` |

- **`aws_region`**: the region where IAM Identity Center is enabled (the console shows it as the
  instance's home region). Buckets, SNS topics and EventBridge rules are created in the same region, so
  your CloudTrail trail must also record events here. *If wrong:* `aws_ssoadmin_instances` returns nothing
  and the plan errors on index `[0]`.
- **`name_prefix`**: first part of every bucket, topic and permission-set name. Bucket names are **globally
  unique** across all AWS accounts, so choose something company-specific. 2-15 chars. Names are built as
  `<prefix>-<local-part-of-email, max 30>-<8-char hash of email>`; the hash prevents collisions between
  `a.b@` and `a-b@`. *Changing it later replaces every resource.*
- **`session_duration`**: ISO-8601 duration, 1-12 hours (`PT1H`...`PT12H`). How long a console/CLI
  session from the per-user permission set lasts before re-authentication.
- **`tags`**: applied to every AWS resource. Add the tags your finance/security teams require.

### Bucket behaviour

| Variable | Required | Default |
|---|---|---|
| `bucket_force_destroy` | no | `false` |
| `bucket_noncurrent_version_expiration_days` | no | `0` (off) |

- **`bucket_force_destroy`**: if `true`, Terraform may delete a bucket that still holds objects. Keep `false`:
  the last step of offboarding (removing a user from the OFFBOARDED group) then **fails safe** on a non-empty bucket.
- **`bucket_noncurrent_version_expiration_days`**: versioning is always on; every overwrite or delete keeps
  the old version and costs money forever. A positive number deletes old versions after that many days and
  aborts stalled multipart uploads after 7. `0` keeps everything. Pick from your retention policy.

### Notifications

| Variable | Required | Default |
|---|---|---|
| `bucket_object_event_types` | no | created + removed |
| `enable_config_change_notifications` | no | `true` |
| `bucket_config_event_names` | no | 22 bucket-configuration API names |

- **`bucket_object_event_types`**: S3 event-notification type strings (e.g. `s3:ObjectCreated:*`) that email the
  recipient. Busy buckets generate one email per event; narrow this if volume is a problem.
- **`enable_config_change_notifications`**: emails when a bucket's *configuration* changes (policy, ACL,
  encryption, public-access block...). Works through CloudTrail → EventBridge, so a trail that records
  **management events in `aws_region`** must already exist. *If you have no trail and leave this `true`,*
  Terraform succeeds but no configuration emails ever arrive. Set `false` to make that explicit.
- **`bucket_config_event_names`**: the CloudTrail API names that count as a configuration change. Add or remove
  to taste. Note that Terraform's own changes also trigger these emails.

### Okta

| Variable | Required | Default |
|---|---|---|
| `okta_org_name` | **yes** | none |
| `okta_base_url` | no | `okta.com` |
| `okta_group_name` | no | `aws-user-bucket-eligible` |
| `okta_offboarded_group_name` | no | `aws-user-bucket-offboarded` |
| `okta_departed_group_name` | no | `null` (disabled) |
| `scim_username_attribute` | no | `email` |
| `delegate_username_overrides` | no | `{}` |

- **`okta_org_name`**: from your Okta URL `https://<this>.okta.com`.
- **`okta_base_url`**: `okta.com` (production), `oktapreview.com` (preview orgs), `okta-emea.com` (EMEA).
- **`okta_group_name`** / **`okta_offboarded_group_name`** / **`okta_departed_group_name`**: exact group names; the
  meaning of each is in [OKTA_WORKFLOWS.md](OKTA_WORKFLOWS.md#1-the-model-in-one-picture). *If a name doesn't exist,*
  the plan errors on that data source. Leaving DEPARTED `null` weakens one safety check (a departed manager with no bucket can be chosen as a delegate).
- **`scim_username_attribute`**: open one SCIM-provisioned user in the Identity Center console and see whether
  its *Username* equals the user's Okta **email** or Okta **login** (they usually match, but not always).
  *If wrong:* the active-owner lookup fails with "user not found".
- **`delegate_username_overrides`**: delegates come from the `manager` map, so only their email is known.
  Use this for any delegate whose Identity Center username differs from their email:
  `{ "<DELEGATE_EMAIL>" = "<IDENTITY_CENTER_USERNAME>" }`.

### Manager chain

| Variable | Required | Default |
|---|---|---|
| `manager` | no (but see below) | `{}` |
| `fallback_delegate_email` | no | `null` |

- **`manager`**: `{ "<user email>" = "<that user's manager email>" }`, case-insensitive.
  - Chain walk: owner → `manager[owner]` → `manager[manager[owner]]` … up to **5 levels**. The first person who is
    **not departed and not the owner** inherits.
  - *Maintenance rules:* (1) add every user who will own a bucket; (2) when someone leaves, re-point their
    direct reports to the leaver's manager (or the chain skips the leaver automatically only while they are
    in OFFBOARDED/DEPARTED); (3) apply Terraform after any change, because `offboard.yml` reads the delegate from the
    last applied state.
  - *If empty:* every offboarded user falls back to `fallback_delegate_email`, or the plan fails if that is `null`.
- **`fallback_delegate_email`**: your safety net, e.g. an IT/security owner mailbox. It must exist in Google
  Workspace **and** Identity Center, and be in `email_domain`. With `null`, an unresolvable delegate **fails the plan**
  (the plan refuses to leave a bucket unowned).

### Google Workspace

| Variable | Required | Default |
|---|---|---|
| `email_domain` | **yes** | none |
| `gws_credentials_file` | **yes** (sensitive) | none |
| `gws_customer_id` | **yes** | none |
| `gws_impersonated_admin` | **yes** | none |
| `gws_oauth_scopes` | no | directory read-only |

- **`email_domain`**: your Workspace primary domain **without** `@`. Guardrail: every recipient (owner or delegate)
  must end in `@<this>`, otherwise the plan refuses to provision (stops mail going to personal addresses).
- **`gws_credentials_file`**: path to the service-account JSON key. Locally, wherever you saved it; in CI the workflow
  writes the `GWS_SA_KEY` secret to `./sa-key.json`, so use `./sa-key.json`.
- **`gws_customer_id`**: Admin console → Account → Account settings → *Customer ID* (starts with `C`).
- **`gws_impersonated_admin`**: a real Workspace admin; the service account acts as them via domain-wide delegation.
- **`gws_oauth_scopes`**: Terraform only *reads* the directory (confirms the recipient exists). If the provider
  returns HTTP 403, widen to `https://www.googleapis.com/auth/admin.directory.user`.

---

## 2. Provider environment variables

Never put these in `terraform.tfvars`.

| Variable | Used by | Meaning |
|---|---|---|
| `OKTA_API_TOKEN` | Okta provider | Okta API token for a read-only admin (users, groups). Simplest option. |
| `OKTA_API_CLIENT_ID`, `OKTA_API_PRIVATE_KEY`, `OKTA_API_PRIVATE_KEY_ID`, `OKTA_API_SCOPES` | Okta provider | OAuth 2.0 service-app alternative to the token (scopes: read users/groups). |
| AWS credentials | AWS provider | Locally: your usual profile/SSO. In CI: the OIDC role (below). |

---

## 3. GitHub secrets, variables and environments

Repository → Settings → Secrets and variables → Actions.

| Name | Kind | Value | Used by |
|---|---|---|---|
| `OKTA_API_TOKEN` | secret | Okta read-only API token | `terraform.yml` |
| `TFVARS` | secret | Full contents of your `terraform.tfvars` (with `gws_credentials_file = "./sa-key.json"`) | both |
| `GWS_SA_KEY` | secret | Full JSON of the Google service-account key | both |
| `AWS_ROLE_ARN` | variable | ARN of an IAM role trusted for GitHub OIDC (state access + Terraform permissions) | both |
| `AWS_REGION` | variable | Region for the AWS session (match `aws_region`) | both |
| `GWS_ADMIN_EMAIL` | variable | Workspace admin the transfer script impersonates | `offboard.yml` |

**Environments** (Settings → Environments):

| Environment | Reviewers | Used for |
|---|---|---|
| `production` | **required** (humans) | Manual `terraform.yml` runs by people |
| `terraform-auto` | none | `terraform.yml` runs started by Okta (pass as `environment` input) |
| `offboarding` | none | `offboard.yml` (name is fixed in the workflow) |

Restrict all three to the `main` branch. Automation must not wait on a human, and humans must approve manual applies.

**Okta Workflows' GitHub token** (a Workflows connection, *not* a repo secret): fine-grained PAT for this repo only,
permission *Actions: Read and write*, calendar a renewal reminder before it expires.

---

## 4. Transfer script arguments

`scripts/gws_offboard_transfer.py` (all supplied by `offboard.yml`; run by hand for testing).

| Argument | Required | Meaning |
|---|---|---|
| `--owner` | yes | Departing user's email |
| `--delegate` | yes | Receiving user's email (taken from Terraform output so AWS and Google agree) |
| `--sa-key` | yes | Service-account JSON path |
| `--admin` | yes | Workspace admin to impersonate |
| `--timeout` | no (3600) | Seconds to wait for Google's asynchronous transfer |
| `--poll-seconds` | no (30) | Status polling interval |
| `--only-apps` | no (all) | Comma-separated Google app names (e.g. `Drive and Docs,Calendar`) |
| `--skip-gmail-delegate` | no | Skip creating mailbox delegation |
| `--dry-run` | no | Print what would transfer; change nothing |

Domain-wide delegation scopes the service account needs (Admin console → Security → API controls):
`admin.directory.user.readonly`, `admin.datatransfer`, `gmail.settings.sharing`.
