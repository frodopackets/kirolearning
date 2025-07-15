variable "bucket_suffix" {
  description = "Random suffix for resource names to ensure uniqueness"
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket for PDF documents"
  type        = string
}

variable "orchestration_api_role_arn" {
  description = "ARN of the orchestration API IAM role"
  type        = string
}