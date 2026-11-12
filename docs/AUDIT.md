# Audit document: what is here, what it does, what is missing, what is needed

Status: **unexecuted design.** No part of this has been run against a live Okta, AWS or Google tenant, and
`terraform validate` has not been run (no Terraform binary was available when it was written). The CI
`validate` job is the first real check. Treat every claim below as "intended behavior" until your first plan/apply.

## 1. Inventory

| Path | What it is |
|---|---|
| `terraform/versions.tf` | Provider versions (aws, okta, googleworkspace) and provider auth wiring |
| `terraform/variables.tf` | Every input, with description, default, validation |
| `terraform/main.tf` | All resources (see section 2) |
| `terraform/outputs.tf` | Audit output, `offboarding_delegates`, `unavailable_delegate_emails` |
| `terraform/terraform.tfvars.example` | Placeholder template for all inputs |
| `scripts/gws_offboard_transfer.py` | Google Workspace Drive/Docs/Calendar transfer + Gmail delegation |
| `.github/workflows/terraform.yml` | fmt/validate on PR; plan/apply on dispatch |
| `.github/workflows/offboard.yml` | Runs the Google transfer, called by Okta |
| `docs/OKTA_WORKFLOWS.md` | The Okta Workflows needed, and optimizations |
| `docs/VARIABLES.md` | Write-up of every variable/secret/argument |
| `README.md` | Step-by-step setup and operation |

## 2. What it does

**Per user in the ELIGIBLE Okta group** Terraform creates: a private, encrypted (SSE-S3), versioned,
TLS-only S3 bucket; an IAM Identity Center permission set limited to that bucket and assigned to the user;
an SNS topic with an email subscription to the user's Google address; S3 object-event notifications; and
(optionally) CloudTrail→EventBridge notifications for bucket-configuration changes.

**When a user moves to the OFFBOARDED group** the bucket and its data stay. The permission-set assignment
moves from the user to the *delegate*, and the SNS email subscription moves to the delegate. The delegate is
the first available person up the `manager` map (5 levels), else `fallback_delegate_email`, else the plan fails.

**Google assets** are moved by `gws_offboard_transfer.py`, not Terraform: Drive/Docs, Calendar and any other
Google-listed transferable app go to the delegate via the Data Transfer API; Gmail is made accessible to the
delegate via mailbox delegation.

**Okta Workflows** sequence it all (transfer → group moves → sessions/tokens → deactivate → Terraform).

## 3. What is missing (known gaps)

| # | Gap | Impact | Notes |
|---|---|---|---|
| 1 | **Not run or validated** | Unknown syntax/provider-schema errors | CI validate + a test user will surface these |
| 2 | **Gmail contents are not transferred** | Delegate gets access, not a copy | Google has no Gmail transfer API; Vault export is the retention path (not built) |
| 3 | **SNS email needs one click to confirm** | No notifications until the recipient confirms | AWS limitation; SNS→Lambda→SES removes it (not built) |
| 4 | **Manager map is manual** | Stale map ⇒ wrong delegate | Okta `managerId` could feed it (optimization 1) |
| 5 | **Delegate is read from last-applied state** | Manager changes are invisible until next apply | Optimization 3 |
| 6 | **Chain depth fixed at 5** | Deep orgs fall to fallback | Add `chain_N` locals |
| 7 | **One AWS account** | Buckets and assignment target the account Terraform runs in | Multi-account needs provider aliases |
| 8 | **SSE-S3 only, no KMS** | Meets baseline, not CMK-controlled access | Add a CMK variable + key-policy/permission changes |
| 9 | **No Okta/Google resources are managed by Terraform** | Groups, SCIM app, Workflows, Google service account are created by hand | Okta provider could manage groups; left manual to keep Terraform read-only on Okta |
| 10 | **Okta Workflows themselves are not code** | Flows are built in the Okta UI from `docs/OKTA_WORKFLOWS.md` | Workflows can be exported as `.flo` files once built and committed |
| 11 | **Third-party/app data outside Google/AWS** | Not transferred | Out of scope |
| 12 | **No `.terraform.lock.hcl`** | Provider versions float within ranges | Run `terraform init` once and commit the lock file |
| 13 | **Okta API behaviors marked [verify]** | e.g. token revocation, `syncState`, group member listing for deactivated users | Test with a throwaway user |

## 4. What is needed to run it (checklist)

**Okta:** groups ELIGIBLE/OFFBOARDED/DEPARTED/OFFBOARDING-REQUESTED; SCIM app to AWS Identity Center; Google
Workspace app set to *suspend* (not delete); read-only API token for Terraform; Workflows with Okta + GitHub
connections, the constants/table in `OKTA_WORKFLOWS.md`, and Flows 1-5.

**AWS:** IAM Identity Center enabled in one region; SCIM provisioning token given to Okta; a CloudTrail trail
(management events, same region) if config-change emails are wanted; a remote Terraform state backend; an IAM
role trusted by GitHub OIDC. Its permissions must cover the services Terraform manages, i.e. S3 bucket
configuration, SNS, EventBridge, IAM Identity Center (`sso:*` admin and identity store read), and the
service-linked-role/IAM actions Identity Center needs when provisioning permission sets. Start broad in a
sandbox, then scope down using CloudTrail's access history. **[verify]**

**Google Workspace:** a service account with domain-wide delegation granted exactly: `admin.directory.user.readonly`,
`admin.datatransfer`, `gmail.settings.sharing`; the customer ID; an admin to impersonate.

**GitHub:** the secrets, variables and three environments in `docs/VARIABLES.md` §3.

## 5. Assumptions baked into the code (check each)

1. Identity Center `UserName` = Okta email (or login via `scim_username_attribute`); delegates use email unless overridden.
2. SNS, S3 and EventBridge are in the same region as Identity Center.
3. Okta lists deactivated users in group member lists and `okta_user` can read them by ID.
4. A user is "an owner" only through group membership; a user in both ELIGIBLE and OFFBOARDED is treated as offboarded.
5. Google Workspace users are suspended, never deleted, until transfer finishes.
6. Everyone's email is in `email_domain`.

## 6. Security review notes

- **Secrets** (`OKTA_API_TOKEN`, `TFVARS`, `GWS_SA_KEY`) live only in GitHub secrets; workflows write the key/tfvars to disk
  with `umask 077` and always delete them. State may contain emails; encrypt the backend.
- **Least privilege:** Terraform's Okta credential is read-only; Okta Workflows' GitHub token is limited to this repo's Actions.
- **Highest-risk capability:** the service account can transfer any user's Drive/Calendar and delegate any mailbox
  (domain-wide delegation). Restrict who can run `offboard.yml` (environment rules, branch protection, CODEOWNERS on `scripts/` and `.github/`).
- **Privacy:** giving a manager mailbox access is a legal/HR decision. Confirm policy before enabling `offboard.yml` for real users.
- **Blast radius guards in code:** recipient domain check; refuse to leave a bucket without an owner; `force_destroy=false`;
  public access fully blocked; TLS-only bucket policy.
- **Terraform's own changes email owners** through the config-change rule.

## 7. Suggested verification order

1. `terraform fmt -check && terraform init && terraform validate` in `terraform/`.
2. `terraform plan` with empty groups: expect no changes, no errors (proves Okta/AWS/Google auth).
3. Put one test user in ELIGIBLE: plan shows their resources; apply; confirm bucket, SSO access, SNS confirmation email.
4. Run `offboard.yml` with `dry_run=true` for that user.
5. Run Flow 2 for the test user (real), confirm the delegate gets Drive/Calendar, mailbox delegation, AWS access and emails.
