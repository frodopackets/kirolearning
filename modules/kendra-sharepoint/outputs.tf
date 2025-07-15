output "kendra_index_id" {
  value       = aws_kendra_index.sharepoint_index.id
  description = "ID of the Kendra index for SharePoint content"
}

output "kendra_index_arn" {
  value       = aws_kendra_index.sharepoint_index.arn
  description = "ARN of the Kendra index for SharePoint content"
}

output "sharepoint_data_source_id" {
  value       = aws_kendra_data_source.sharepoint_connector.id
  description = "ID of the SharePoint data source"
}

output "sharepoint_credentials_secret_arn" {
  value       = aws_secretsmanager_secret.sharepoint_credentials.arn
  description = "ARN of the SharePoint credentials secret"
}

output "jwt_signing_key_secret_arn" {
  value       = aws_secretsmanager_secret.jwt_signing_key.arn
  description = "ARN of the JWT signing key secret"
}

output "kendra_security_group_id" {
  value       = aws_security_group.kendra.id
  description = "Security group ID for Kendra connector"
}