terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60, < 7.0"
    }
    okta = {
      source  = "okta/okta"
      version = ">= 4.6, < 6.0"
    }
    googleworkspace = {
      source  = "hashicorp/googleworkspace"
      version = "~> 0.7"
    }
  }

  # Configure a remote backend before real use (S3 + DynamoDB lock, TFC, etc.)
  # backend "s3" {}
}

provider "aws" {
  # Must be the Identity Center home region (buckets, SNS and EventBridge live here too).
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}

# Auth via env var: OKTA_API_TOKEN (or OKTA_API_PRIVATE_KEY / OKTA_API_CLIENT_ID for OAuth)
provider "okta" {
  org_name = var.okta_org_name
  base_url = var.okta_base_url
}

# Service account with domain-wide delegation, impersonating a Workspace admin (read-only here).
provider "googleworkspace" {
  credentials             = var.gws_credentials_file
  customer_id             = var.gws_customer_id
  impersonated_user_email = var.gws_impersonated_admin
  oauth_scopes            = ["https://www.googleapis.com/auth/admin.directory.user.readonly"]
}
