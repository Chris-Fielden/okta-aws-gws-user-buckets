# okta-aws-gws-user-buckets

Okta (SSO + SCIM) -> AWS IAM Identity Center -> per-user S3 bucket, with change notifications to the
user's Google Workspace email. On offboarding, everything transfers to the manager (chain-walked).

> Status: unexecuted draft. Not yet run against a live Okta/AWS/Google tenant.

## Layout

```
.
├── README.md
├── .gitignore
├── .github/workflows/
│   ├── terraform.yml            # validate on PR; plan/apply via manual dispatch
│   └── offboard.yml             # Google transfer, triggered by Okta Workflows
├── docs/
│   └── OFFBOARDING_RUNBOOK.md   # required order of operations
├── scripts/
│   ├── gws_offboard_transfer.py # Drive/Docs/Calendar transfer + Gmail delegation
│   └── requirements.txt
└── terraform/
    ├── versions.tf              # providers: aws, okta, googleworkspace
    ├── variables.tf
    ├── main.tf                  # groups -> owners -> delegate chain -> bucket/SSO/SNS
    ├── outputs.tf               # audit output + offboarding_delegates
    └── terraform.tfvars.example
```

## What Terraform builds per user

S3 bucket (private, encrypted, versioned, TLS-only) - IAM Identity Center permission set scoped to
that bucket and assigned to the user - SNS topic with email subscription to the user's Google email -
S3 object events + CloudTrail/EventBridge bucket-config changes routed to that topic.

## Gating

| Okta group | Meaning | Access + email go to |
|---|---|---|
| `aws-user-bucket-eligible` | passed automation checks | the user |
| `aws-user-bucket-offboarded` | offboarded by workflow | first available person up `var.manager` chain, else fallback |

## Quick start

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit; never commit
export OKTA_API_TOKEN=...
terraform init && terraform plan
```

## Known limits

- SNS email subscriptions require the recipient to confirm once (AWS).
- Gmail contents cannot be transferred by API; delegation only.
- Chain depth is fixed at 5 levels (add `chain_N` locals in `main.tf` to extend).
- One permission set per user; Identity Center caps these at ~500.
- Requires an existing CloudTrail trail for bucket-configuration-change emails.

## Required GitHub configuration

Secrets: `OKTA_API_TOKEN`, `TFVARS` (contents of tfvars), `GWS_SA_KEY` (service account JSON).
Variables: `AWS_ROLE_ARN`, `AWS_REGION`, `GWS_ADMIN_EMAIL`. Environment: `production` with required reviewers.
