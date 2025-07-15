variable "s3_bucket_name" {
  description = "Name of the S3 bucket for PDF documents"
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket for PDF documents"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "lambda_dlq_arn" {
  description = "ARN of the Lambda dead letter queue"
  type        = string
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic for alerts"
  type        = string
}

variable "lambda_zip_base64" {
  description = "Base64 encoded Lambda function code"
  type        = string
}