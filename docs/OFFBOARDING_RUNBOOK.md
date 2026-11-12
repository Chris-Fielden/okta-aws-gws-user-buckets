# Offboarding runbook

Okta Workflows owns the sequence. Do not reorder.

1. **Transfer Google assets** — call the `offboard-google-transfer` GitHub workflow
   (`POST /repos/{owner}/{repo}/actions/workflows/offboard.yml/dispatches`,
   inputs: `owner`). Wait for the run to finish. **If it fails, stop and alert; do not continue.**
   - Drive/Docs, Calendar and every other app Google lists as transferable move to the delegate.
   - Gmail is **not** transferred (no API): the delegate gets mailbox delegation.
     Use a Google Vault export if you need a retained copy.
2. **Add the user to `aws-user-bucket-offboarded`** (and remove from `aws-user-bucket-eligible`).
3. **Deactivate the user in Okta and revoke all API tokens and sessions.**
4. **Run the `terraform` workflow (plan, then apply).** AWS access and notifications move to the delegate.

## Preconditions (verify once)

- Okta's Google Workspace app **suspends** on deactivation and does not delete the account.
  Deleting before step 1 completes destroys the data.
- The delegate's SCIM user exists in IAM Identity Center and their Google account is active.
- The delegate is read from Terraform *state*; apply after changing `var.manager`, before offboarding.
- SNS email subscriptions need a one-time click from the recipient (AWS limitation).

## Delegate resolution

`var.manager` maps user -> manager. The delegate is the first person up the chain (5 levels)
who is not already offboarded; otherwise `fallback_delegate_email`; otherwise the plan fails.

## Cleanup

After the delegate has archived or reassigned the data, remove the user from the offboarded group.
Terraform plans to destroy their bucket; `force_destroy = false` blocks until it is empty.
