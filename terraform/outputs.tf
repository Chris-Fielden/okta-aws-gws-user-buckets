output "provisioned_users" {
  description = "Per-owner resources and current delegation, for audit."
  value = {
    for k, u in local.users : k => {
      owner           = u.email
      state           = u.offboarded ? "offboarded" : "active"
      delegate_source = u.delegate_source
      access_held_by  = u.effective_login
      notify_email    = data.googleworkspace_user.this[k].primary_email
      bucket          = aws_s3_bucket.user[k].id
      permission_set  = aws_ssoadmin_permission_set.user[k].name
      sns_topic       = aws_sns_topic.user[k].arn
    }
  }
}

output "offboarding_delegates" {
  description = "owner email => who inherits their assets if offboarded now. Feed this to the Google transfer script so AWS and Google go to the same person."
  value       = { for u in local.users : u.email => u.delegate_email }
}
