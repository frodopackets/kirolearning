variable "bucket_suffix" {
  description = "Random suffix for resource names to ensure uniqueness"
  type        = string
}

variable "kendra_index_id" {
  description = "ID of the Kendra index for SharePoint content"
  type        = string
}

variable "kendra_index_arn" {
  description = "ARN of the Kendra index for SharePoint content"
  type        = string
}

variable "knowledge_base_id" {
  description = "ID of the Bedrock Knowledge Base"
  type        = string
}

variable "knowledge_base_arn" {
  description = "ARN of the Bedrock Knowledge Base"
  type        = string
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for document storage"
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket for document storage"
  type        = string
}

variable "sharepoint_credentials_secret_arn" {
  description = "ARN of the SharePoint credentials secret"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for Lambda VPC configuration"
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security group ID for Lambda functions"
  type        = string
}

variable "lambda_zip_path" {
  description = "Path to the Lambda function ZIP file"
  type        = string
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic for alerts"
  type        = string
}