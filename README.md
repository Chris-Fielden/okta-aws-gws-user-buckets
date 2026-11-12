# Okta + AWS + Google Workspace: per-user buckets with automatic offboarding

A user who passes your automation checks gets a private S3 bucket in AWS, access to only that bucket
through IAM Identity Center, and emails to their Google Workspace address about activity on it. When they
leave, the bucket, their Google assets and the emails all transfer to their manager (or the next person up
the chain).

> **Status: unexecuted design.** Not yet run against live tenants; see [docs/AUDIT.md](docs/AUDIT.md) for
> exactly what is verified, missing and assumed.

## How the three systems fit together

```
        OKTA  (identity + automation)
   ┌───────────────────────────────────────┐
   │ Groups: ELIGIBLE / OFFBOARDED /       │      SCIM       ┌──────────────────────────┐
   │         DEPARTED / REQUESTED          ├────────────────►│ AWS IAM Identity Center  │
   │ Workflows 1-5 (conductor)             │                 └─────────────▲────────────┘
   └───────┬───────────────────┬───────────┘                               │ assignment
           │ read groups       │ dispatch                                  │
           ▼                   ▼                                  ┌────────┴────────┐
   ┌──────────────┐   ┌────────────────────┐   applies          │ AWS: S3 bucket, │
   │  Terraform   │◄──┤ GitHub Actions     ├───────────────────►│ permission set, │
   │ (this repo)  │   │ terraform.yml      │                    │ SNS, EventBridge│
   └──────┬───────┘   │ offboard.yml       │                    └────────┬────────┘
          │ read      └─────────┬──────────┘                             │ emails
          ▼                     │ Data Transfer + Gmail delegation       ▼
   ┌──────────────────────────────────────────────────────────────────────────┐
   │ GOOGLE WORKSPACE: user directory (read), Drive/Docs/Calendar (transfer), │
   │ Gmail (delegation), recipient inbox for notifications                    │
   └──────────────────────────────────────────────────────────────────────────┘
```

**Division of labor.** Okta decides *who and when* (group membership). Terraform builds *AWS*. A Python
script moves *Google data* (Terraform cannot). GitHub Actions runs both on demand. Okta Workflows calls
GitHub in the right order.

## Documentation map

| Read this | For |
|---|---|
| This README | Setup and operation, step by step |
| [docs/VARIABLES.md](docs/VARIABLES.md) | What every variable, secret and argument means and where to find it |
| [docs/OKTA_WORKFLOWS.md](docs/OKTA_WORKFLOWS.md) | The Okta flows you must build, plus optimizations |
| [docs/AUDIT.md](docs/AUDIT.md) | What exists, what it does, what is missing, what is needed |

## Repository layout

```
.
├── README.md
├── .gitignore                          # blocks state, tfvars, keys
├── .github/workflows/
│   ├── terraform.yml                   # fmt/validate on PR; plan/apply on dispatch
│   └── offboard.yml                    # Google transfer, started by Okta
├── docs/
│   ├── AUDIT.md
│   ├── OKTA_WORKFLOWS.md
│   └── VARIABLES.md
├── scripts/
│   ├── gws_offboard_transfer.py        # Drive/Docs/Calendar transfer + Gmail delegation
│   └── requirements.txt
└── terraform/
    ├── versions.tf                     # providers + auth wiring
    ├── variables.tf                    # all inputs
    ├── main.tf                         # all resources
    ├── outputs.tf
    └── terraform.tfvars.example        # placeholder template
```

## What gets created

Per user in the ELIGIBLE group (Terraform, `terraform/main.tf`):

1. S3 bucket named `<name_prefix>-<email local part>-<hash>`: private (all public access blocked), SSE-S3,
   versioned, TLS-only, owner-enforced ACLs.
2. IAM Identity Center permission set allowing read/write on **only that bucket**, assigned to the user.
3. SNS topic + email subscription to the user's Google address.
4. S3 object-event notifications → the topic.
5. (Optional) CloudTrail→EventBridge rule: emails on bucket *configuration* changes.

When the user moves to OFFBOARDED: items 1-5 stay; the assignment (2) and subscription (3) move to the delegate.

---

# Setup, step by step

Do the steps in order. Each ends with a check.

## Step 0: Decide your values

Before touching anything, fill in this list. Every item maps to a variable in
[docs/VARIABLES.md](docs/VARIABLES.md).

- [ ] Okta org subdomain, and Okta base URL
- [ ] Google Workspace primary domain and customer ID, plus an admin email
- [ ] AWS account, and the region where Identity Center lives
- [ ] A company-unique bucket `name_prefix`
- [ ] A fallback owner account (real, monitored mailbox)
- [ ] Your manager relationships (user → manager)
- [ ] Your retention decision for old object versions (days, or keep all)
- [ ] GitHub org/user and repository name

## Step 1: Okta

1. **Create four groups:** ELIGIBLE, OFFBOARDED, DEPARTED, OFFBOARDING-REQUESTED. No group rules.
   Record each group's name and ID. *Check:* the four exist and are empty.
2. **SCIM to AWS:** set up the *AWS IAM Identity Center* app in Okta with SCIM provisioning (token from the
   Identity Center console, Settings → Automatic provisioning). Assign it to ELIGIBLE and to everyone who can ever be a
   delegate (all managers, the fallback owner). *Check:* a test user appears in Identity Center's user list.
3. **Google Workspace app:** ensure provisioning **suspends** deactivated users, never deletes them.
4. **Terraform's credential:** create a read-only API token (or OAuth service app) for users and groups. You will
   store it as `OKTA_API_TOKEN`.
5. **Workflows:** you will build these after the rest is working (Step 8).

## Step 2: AWS

1. **Identity Center** enabled; note its home region (`aws_region`).
2. **CloudTrail** trail with management events in that region *(only if you want configuration-change emails;
   otherwise set `enable_config_change_notifications = false`)*.
3. **State backend**: create an S3 bucket + DynamoDB lock table (or use Terraform Cloud) and uncomment/configure the
   `backend` block in `terraform/versions.tf`. The GitHub workflows need shared state.
4. **GitHub OIDC role**: create an IAM OIDC identity provider for GitHub and a role trusted by this repository,
   with permissions for the backend and the services in [docs/AUDIT.md §4](docs/AUDIT.md). Record the ARN (`AWS_ROLE_ARN`).

## Step 3: Google Workspace

1. Create a **service account** in a Google Cloud project; enable the *Admin SDK API* and *Gmail API*; create a JSON key.
2. In the Admin console → Security → API controls → *Domain-wide delegation*, add the service account's client ID with
   exactly these scopes:
   - `https://www.googleapis.com/auth/admin.directory.user.readonly`
   - `https://www.googleapis.com/auth/admin.datatransfer`
   - `https://www.googleapis.com/auth/gmail.settings.sharing`
3. Note the **customer ID** and choose the **admin** the service account will impersonate.

## Step 4: GitHub

1. Create the repository (private) and push this code.
2. Add the secrets, variables and **three environments** (`production` with reviewers, `terraform-auto`, `offboarding`) listed in
   [docs/VARIABLES.md §3](docs/VARIABLES.md#3-github-secrets-variables-and-environments).
3. Protect `main` and require review on `scripts/` and `.github/` (they can move company data).

## Step 5: Configure the variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars     # git-ignored
```

Replace every `<PLACEHOLDER>`. Paste the same content into the `TFVARS` GitHub secret (with
`gws_credentials_file = "./sa-key.json"`).

## Step 6: First local run (empty groups)

```bash
export OKTA_API_TOKEN=<your token>
# AWS credentials: your normal profile / SSO login
cd terraform
terraform init
terraform fmt -check
terraform validate
terraform plan
```

*Check:* plan completes with **"No changes"**. That proves Terraform can authenticate to Okta, AWS and Google, and
find the three groups. Commit the generated `.terraform.lock.hcl`.

Likely errors here: group name typo; Identity Center in another region; Okta token lacks read access.

## Step 7: Onboard one test user

1. Pick a real test user; add them to the SCIM app, ensure their Google account exists, add them to `manager`.
2. Add them to ELIGIBLE in Okta.
3. `terraform plan` → expect their bucket, permission set, assignment, SNS topic/subscription, notification, EventBridge rule.
4. `terraform apply`.
5. *Checks:*
   - The user signs in through Okta and sees the AWS account with their permission set; they can list/put in
     **their** bucket and get "access denied" on every other bucket.
   - They receive an AWS "Confirm subscription" email; they click it (AWS requirement; the email path is silent until then).
   - Uploading an object triggers a notification email.

## Step 8: Build the Okta Workflows

Follow [docs/OKTA_WORKFLOWS.md](docs/OKTA_WORKFLOWS.md): constants, the `offboarding_jobs` table, and Flows 1-5.
Create the GitHub PAT for Workflows (repo-scoped, *Actions: Read and write*).

## Step 9: Rehearse offboarding

1. **Dry run:** run `offboard-google-transfer` manually in GitHub with the test user and `dry_run = true`.
   *Check:* the log lists the applications that would transfer and the delegate chosen.
2. **Real run with a throwaway account:** add the throwaway user to OFFBOARDING-REQUESTED. Watch Flow 2 → GitHub →
   Flow 3. *Checks:* the delegate has the Drive/Calendar items, can open the old mailbox (delegation),
   the throwaway user can no longer sign in, the bucket still exists tagged `LifecycleState = offboarded`, and the
   **delegate** now holds the AWS permission set and gets the emails (after confirming the new subscription).

---

# Day-to-day operation

| Task | How |
|---|---|
| Onboard a user | Flow 1 adds them to ELIGIBLE (after checks); Flow 4 applies |
| Change a manager | Edit `manager` in `terraform.tfvars` **and the `TFVARS` secret**, then run `terraform.yml` with `apply=true` |
| Offboard a user | Put them in OFFBOARDING-REQUESTED; Flows 2 and 3 do the rest |
| Check current state | `terraform output provisioned_users` |
| Final cleanup of a departed user's bucket | Delegate empties/archives it; remove the user from OFFBOARDED; Terraform plans the destroy and `force_destroy=false` blocks until the bucket is empty |
| Extend the manager chain beyond 5 | Add `chain_6…` locals in `main.tf` |
| Verify state vs. reality | `terraform plan` (should be empty) |

# Troubleshooting

| Symptom | Likely cause |
|---|---|
| Plan: "no users found" for an owner/delegate | Their Identity Center user doesn't exist yet (SCIM not synced) or `scim_username_attribute` is wrong |
| Plan: precondition "no available delegate" | `manager` has no usable chain for that user and `fallback_delegate_email` is `null` |
| Plan: precondition "not in @domain" | A recipient's email is outside `email_domain` |
| Plan fails for **everyone** because of one user | One data lookup failed (see first two rows); fix that user or remove them from the group |
| No notification emails | Subscription not confirmed; no CloudTrail trail (config-change emails); wrong `bucket_object_event_types` |
| `offboard.yml`: "No delegate … in Terraform state" | User not applied yet or `manager` changed without an apply |
| Google transfer "failed" | Delegate suspended; scopes missing in domain-wide delegation; user already deleted (not suspended) |
| Gmail delegation error | Owner mailbox already suspended (delegation needs an active mailbox) |
| Okta flow didn't deactivate the user | By design: the Google transfer failed, so deactivation was withheld |

# Known limits

See [docs/AUDIT.md §3](docs/AUDIT.md) for the full list. The important ones: Gmail contents are not copied (delegation
only); SNS email needs a one-time confirmation click; the manager map is maintained by hand; nothing has been run yet.
