# Okta Workflows required to run this system

Terraform builds AWS resources from **Okta group membership**. It cannot move Google data, and it cannot
deactivate anyone. Okta Workflows is the conductor: it decides *when* people enter and leave the groups,
and calls the two GitHub workflows in this repo at the right moments.

> Okta Workflows card names and menus change between releases. Where this page names a card or an
> Okta API endpoint, treat it as the intent and **verify it in your org** (marked **[verify]**).

---

## 1. The model in one picture

```
 HR / admin request ──► FLOW 2  Offboarding start ───────────────┐
                                                                  ▼
 checks pass ─► FLOW 1  Eligibility ─► group: ELIGIBLE      GitHub: offboard.yml
                              │                              (Google transfer + Gmail delegation)
                              ▼                                   │
                      FLOW 4  Reconcile ──► GitHub: terraform.yml │
                              ▲                                   ▼
                              │                          FLOW 3  Offboarding finish (scheduled poller)
                              └──────────────────────────── moves groups, kills sessions/tokens,
                                                            deactivates, triggers terraform apply
```

Three Okta groups drive Terraform (names are Terraform variables; see `docs/VARIABLES.md`):

| Group (variable) | Contains | Effect in Terraform |
|---|---|---|
| ELIGIBLE (`okta_group_name`) | Active users who passed your checks | Bucket + SSO assignment + email to the user |
| OFFBOARDED (`okta_offboarded_group_name`) | Departed users who **owned a bucket** | Same bucket, but access + email go to the delegate |
| DEPARTED (`okta_departed_group_name`, optional) | **Every** departed employee | Only blocks them from being picked as a delegate |

A fourth group, **OFFBOARDING-REQUESTED**, is *Okta-side only* (Terraform never reads it). It is the
trigger that starts Flow 2. Create it, but it need not match any Terraform variable.

### Why three groups, not two
If the OFFBOARDED group held every departed employee, Terraform would create buckets for people who never
had one. If it held only bucket owners, a departed **manager without a bucket** would still look available
and could be chosen as someone's delegate. DEPARTED closes that gap without creating buckets.

---

## 2. One-time Okta setup

1. **Create groups**: ELIGIBLE, OFFBOARDED, DEPARTED, OFFBOARDING-REQUESTED. Use the exact names you put in
   `terraform.tfvars`. Note each group's **ID** (needed by Workflows).
2. **Do not give these groups a rule** (no Okta group rules / no auto-membership). Only the flows below add or
   remove members, so the audit trail is clean.
3. **SCIM to AWS**: the AWS IAM Identity Center SCIM app must be assigned to ELIGIBLE (and to every
   possible delegate, i.e. all managers and the fallback owner). Terraform fails the plan when it cannot find a
   delegate's Identity Center user.
4. **Google Workspace app deprovisioning must SUSPEND, not delete.** Deleting the Google account before
   Flow 2/3 finishes destroys the data being transferred. Verify in the Google Workspace app's
   Provisioning > To App settings. **[verify]**
5. **Terraform's Okta credential**: an API token (or OAuth service app) with *read-only* access to users and
   groups. It never writes to Okta.
6. **Workflows connections** you will create (see section 3):
   - *Okta* connection (OAuth, scopes for reading users/groups, managing group membership, deactivating
     users, and clearing sessions/tokens). **[verify the exact scope names offered]**
   - *API Connector* for GitHub with a **fine-grained personal access token** limited to this one repository,
     permission **Actions: Read and write**. Nothing else.

---

## 3. Workflows constants and table

Create these once and reference them in every flow. (All are *values you must supply*.)

| Name | Type | Value | Purpose |
|---|---|---|---|
| `GH_OWNER_REPO` | constant | `<GITHUB_ORG_OR_USER>/<REPO_NAME>` | GitHub repository path |
| `GH_REF` | constant | `main` | Branch to run workflows from |
| `GH_OFFBOARD_FILE` | constant | `offboard.yml` | Google transfer workflow file |
| `GH_TERRAFORM_FILE` | constant | `terraform.yml` | Terraform workflow file |
| `TF_AUTO_ENVIRONMENT` | constant | `terraform-auto` | GitHub environment **without** reviewers (Okta-triggered applies) |
| `ELIGIBLE_GROUP_ID` | constant | `<OKTA_GROUP_ID>` | |
| `OFFBOARDED_GROUP_ID` | constant | `<OKTA_GROUP_ID>` | |
| `DEPARTED_GROUP_ID` | constant | `<OKTA_GROUP_ID>` | |
| `REQUESTED_GROUP_ID` | constant | `<OKTA_GROUP_ID>` | Trigger group for Flow 2 |
| `ALERT_DESTINATION` | constant | `<ALERT_EMAIL_OR_CHAT_CHANNEL>` | Where failures are sent |
| `POLL_MINUTES` | constant | `5` | Flow 3 cadence |
| `MAX_WAIT_MINUTES` | constant | `120` | Give up and alert after this |

**Table `offboarding_jobs`** (Workflows Table): this is the state machine that survives between flows.

| Column | Meaning |
|---|---|
| `user_id`, `email`, `was_owner` | Who, and whether they were in ELIGIBLE at request time |
| `status` | `REQUESTED` → `TRANSFER_RUNNING` → `TRANSFER_OK` → `FINALIZING` → `TF_RUNNING` → `DONE`, or `FAILED` |
| `transfer_dispatched_at` | ISO-8601 UTC timestamp, taken **before** calling GitHub |
| `tf_dispatched_at`, `tf_reason` | Same, for the Terraform run |
| `error` | Last failure text |

---

## 4. The flows

### Flow 1: Eligibility ("passed the automation checks")

*What "the checks" are is your company's decision; this repo has no opinion.* The contract is only: **add the
user to ELIGIBLE after they pass, and only after the preconditions below are true.**

- **Trigger:** your checks' success event (e.g. a ticket closes, a user is added to a "checks-passed"
  group, an HRIS event). Out of scope for this repo.
- **Preconditions to verify before adding to ELIGIBLE** (otherwise Terraform's plan fails for *everyone*):
  1. User is assigned to the AWS IAM Identity Center SCIM app and provisioning succeeded
     (Okta app-user `syncState` is synchronized: `GET /api/v1/apps/{appId}/users/{userId}`). **[verify]**
  2. User's Google Workspace account exists and is active.
  3. The user has a manager entry in the `manager` Terraform variable (see Flow 5 / optimizations).
  4. User's email ends in your `email_domain`.
- **Action:** *Okta: Add User to Group* (`ELIGIBLE_GROUP_ID`). Then call **Flow 4** (Reconcile).
- **On failure of a precondition:** do **not** add; alert `ALERT_DESTINATION` with which check failed.
- **Idempotent:** adding an existing member is harmless.

### Flow 2: Offboarding start

- **Trigger:** *Okta: User Added to Group* with group = `REQUESTED_GROUP_ID` (your HRIS or an admin puts
  the person there). **Make this flow the only path that deactivates departing users.** If another system
  deactivates them first, the Google account may be suspended before Gmail delegation runs (delegation needs
  an active mailbox).
- **Steps:**
  1. *Read User* → get `id`, `profile.email` (lowercase it).
  2. *Group membership check*: is the user in ELIGIBLE? → `was_owner`.
  3. Insert a row in `offboarding_jobs` with `status = REQUESTED`. If a row already exists for this user with
     a non-final status, **stop** (idempotency; prevents double runs).
  4. Set `transfer_dispatched_at = now (UTC)`; then call GitHub:
     ```
     POST https://api.github.com/repos/{GH_OWNER_REPO}/actions/workflows/{GH_OFFBOARD_FILE}/dispatches
     Accept: application/vnd.github+json
     X-GitHub-Api-Version: 2022-11-28
     Body: {"ref":"{GH_REF}","inputs":{"owner":"<email>","dry_run":"false"}}
     ```
     Expect **HTTP 204** (no body). Any other status → `status = FAILED`, alert, stop.
  5. Set `status = TRANSFER_RUNNING`.
- **Never deactivates anything here.** Deactivation is Flow 3's job, after the transfer is proven.

### Flow 3: Offboarding finish (scheduled poller)

- **Trigger:** *Scheduled flow* every `POLL_MINUTES`. Polling is used because Workflows should not sit
  in a long `wait`, and GitHub's dispatch call returns no run ID.
- **For each row in `offboarding_jobs` where `status` is not `DONE`/`FAILED`:**

**A. `TRANSFER_RUNNING`**
1. Find the GitHub run:
   ```
   GET https://api.github.com/repos/{GH_OWNER_REPO}/actions/workflows/{GH_OFFBOARD_FILE}/runs
       ?event=workflow_dispatch&created=>={transfer_dispatched_at}
   ```
   Pick the run whose `display_title` equals `offboard <email>`.
2. No run yet and elapsed > `MAX_WAIT_MINUTES` → `FAILED`, alert.
3. `status == completed` and `conclusion == success` → `TRANSFER_OK`.
4. `status == completed` and `conclusion != success` → `FAILED` with the run's `html_url` in `error`, alert.
   **The user is not deactivated.** A human fixes the cause, then re-queues (see Failure handling).
5. Otherwise still running → leave and check next poll.

**B. `TRANSFER_OK` → finalize (in this order)**
1. *Add User to Group* → DEPARTED.
2. If `was_owner`: *Add User to Group* → OFFBOARDED, then *Remove User from Group* → ELIGIBLE.
3. *Clear User Sessions* (revoke all sessions). Also revoke OAuth/refresh tokens
   (`DELETE /api/v1/users/{userId}/sessions?oauthTokens=true`). **[verify]**
4. Revoke API tokens the user owns: list `GET /api/v1/api-tokens`, find tokens whose `userId` matches,
   `DELETE /api/v1/api-tokens/{tokenId}`. **[verify; token visibility depends on admin role]**
5. *Deactivate User*. (This also triggers SCIM deprovisioning in AWS and, per setup step 4, **suspends**
   Google.)
6. Set `status = FINALIZING`.

**C. `FINALIZING` → trigger Terraform**
1. Set `tf_reason = "offboard <email> <timestamp>"`, `tf_dispatched_at = now`.
2. ```
   POST .../actions/workflows/{GH_TERRAFORM_FILE}/dispatches
   Body: {"ref":"{GH_REF}","inputs":{"apply":"true","reason":"<tf_reason>","environment":"{TF_AUTO_ENVIRONMENT}"}}
   ```
3. `status = TF_RUNNING`.

**D. `TF_RUNNING`**
1. Poll `.../workflows/{GH_TERRAFORM_FILE}/runs?event=workflow_dispatch&created=>={tf_dispatched_at}`;
   match `display_title` containing `tf_reason`.
2. `completed` + `success` → `DONE`; notify the delegate and the owner's manager (optional).
   `completed` + failure → `FAILED`, alert. *(The user is already deactivated; Terraform can simply be re-run.)*

### Flow 4: Reconcile (keep AWS in step with Okta)

- **Trigger:** *User Added to Group* / *User Removed from Group* for ELIGIBLE (and as a final step of Flow 1).
- **Debounce:** keep a one-row table `last_reconcile`; skip if a dispatch happened in the last 5 minutes.
  (GitHub also serializes runs via the `terraform-state` concurrency group, so a skipped event is safe: the
  queued run picks up current group state.)
- **Action:** dispatch `terraform.yml` with `apply=true`, `reason="reconcile"`, `environment={TF_AUTO_ENVIRONMENT}`.

### Flow 5: Manager map (today: manual; see Optimizations)

Terraform's `manager` variable is maintained by hand for now. The flow-side duty is to **alert when it is
stale**: on *User Updated* where the manager field changed, or when a manager is deactivated, notify
`ALERT_DESTINATION` with "update the `manager` Terraform variable".

---

## 5. Failure handling

| Failure | Where it shows | Result | Fix |
|---|---|---|---|
| Google transfer fails | Flow 3-A | User stays **active**; row `FAILED` | Read the GitHub run log, fix cause, set the row back to `REQUESTED` |
| Delegate not found in Terraform state | `offboard.yml` fails at "Resolve delegate" | Same as above | Add user to `manager` variable or ELIGIBLE, run Terraform apply |
| Terraform plan fails (missing Identity Center/Google user) | Flow 3-D | User already deactivated; resources not yet moved | Provision the missing delegate account; re-dispatch `terraform.yml` |
| GitHub returns non-204 on dispatch | Flow 2/3-C | `FAILED`, alert | Check PAT expiry/permissions |
| Same user queued twice | Flow 2 step 3 | Second request ignored | none |

**Safe to re-run:** every step is idempotent: group adds, Google transfer (re-transfers whatever remains),
Gmail delegation (409 = already exists), and Terraform apply.

---

## 6. Optimizations (ordered by value)

1. **Derive managers from Okta instead of the `manager` variable.** Okta's user profile carries
   `managerId` (usually fed by HRIS). A scheduled GitHub job could read it via the Okta Users API and
   generate a `managers.auto.tfvars.json`, removing hand maintenance and the staleness risk. The Terraform
   side needs no change; only the source of `var.manager` does. (Not built: you asked to keep it a variable for now.)
2. **Replace SNS email with SNS → Lambda → SES.** Removes the one-time "Confirm subscription" click that AWS
   requires for each SNS email subscription, and lets you format emails properly. Not built.
3. **Read the delegate from a plan, not from state.** `offboard.yml` reads the last *applied* state, so a
   manager change is invisible until the next apply. Flow 4 minimizes this by applying on group changes, but
   a plan-based read would remove the window entirely (cost: one bad user could then fail everyone's plan).
4. **Callback instead of polling.** Use an Okta Workflows *API Endpoint* flow (availability depends on your
   plan **[verify]**) that the GitHub job calls on success/failure. Removes Flow 3's polling and the `display_title`
   matching. Flow 3's state machine stays the same.
5. **Batch the Okta lookups.** Terraform makes one Okta call per owner and per departed user at every plan.
   If DEPARTED grows large, prune it (see below) or move to one scheduled job that writes a small JSON of
   "unavailable emails" for Terraform to read.
6. **Prune DEPARTED on a schedule** (e.g. 90 days after departure) *only after* their direct reports'
   `manager` entries have been reassigned; otherwise a departed manager becomes "available" again.
7. **Pre-flight check flow**: a weekly scheduled flow that dispatches `terraform.yml` with `apply=false`
   and alerts on failure, catching missing SCIM/Google accounts before an offboarding depends on them.
8. **Gmail retention**: Gmail cannot be transferred by API. For true retention add a Google Vault export step
   (needs Vault API access; not built).

---

## 7. What this page added or clarified

- The **DEPARTED** group and the logic behind it (section 1): closes the "departed manager picked as delegate" gap.
- **Order of operations** is now enforced by the flows, not just documented: transfer → group moves →
  sessions/tokens → deactivate → Terraform.
- **State machine table** so a failure at any step is visible and resumable.
- **Correlation** of GitHub runs via `run-name` (`display_title`), because GitHub's dispatch API returns no run ID.
- **Two GitHub environments**: one with reviewers for humans, one without (`terraform-auto`, `offboarding`) for Okta-driven runs.
