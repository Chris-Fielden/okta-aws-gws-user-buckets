variable "aws_region" {
  description = "Identity Center home region; buckets, SNS and EventBridge are created here too."
  type        = string
  default     = "us-east-1"
}

variable "okta_org_name" {
  description = "Okta org subdomain: the part before '.okta.com' in your Okta URL."
  type        = string
}

variable "okta_base_url" {
  type    = string
  default = "okta.com"
}

variable "okta_group_name" {
  description = "Okta group that automation adds users to after they pass checks."
  type        = string
  default     = "aws-user-bucket-eligible"
}

variable "okta_offboarded_group_name" {
  description = "Okta group your offboarding automation adds users to. Their resources are delegated to their manager chain."
  type        = string
  default     = "aws-user-bucket-offboarded"
}

variable "manager" {
  description = "Map of user email => that user's manager email. Also used to walk up the chain when a manager is offboarded."
  type        = map(string)
  default     = {}
  # Shape (supply real addresses in terraform.tfvars; see terraform.tfvars.example):
  #   { "<user email>" = "<that user's manager email>", ... }
  # A manager's own entry supplies the next level up the chain.
}

variable "fallback_delegate_email" {
  description = "Used when no one in the manager chain is available (use a real, monitored account such as an IT/security owner). Must be in email_domain and match the SCIM userName in Identity Center. Null = fail the plan instead."
  type        = string
  default     = null
}

variable "email_domain" {
  description = "Your Google Workspace primary domain WITHOUT the '@'. Only recipients whose email ends in it are allowed."
  type        = string

  validation {
    condition     = !startswith(var.email_domain, "@") && length(regexall("\\.", var.email_domain)) > 0
    error_message = "email_domain must be a bare domain such as your Workspace domain (no leading '@')."
  }
}

variable "gws_credentials_file" {
  description = "Path to the Google service account JSON key."
  type        = string
  sensitive   = true
}

variable "gws_customer_id" {
  description = "Google Workspace customer ID (Admin console > Account > Account settings)."
  type        = string
}

variable "gws_impersonated_admin" {
  description = "Workspace admin the service account impersonates."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for all per-user resource names (keep short)."
  type        = string
  default     = "ub"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,14}$", var.name_prefix))
    error_message = "name_prefix must be 2-15 chars: lowercase letters, digits, hyphens."
  }
}

variable "session_duration" {
  description = "Identity Center session duration (ISO-8601)."
  type        = string
  default     = "PT8H"
}

variable "tags" {
  type = map(string)
  default = {
    ManagedBy = "terraform"
    Purpose   = "per-user-bucket"
  }
}
