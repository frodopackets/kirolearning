variable "bucket_suffix" {
  description = "Random suffix for resource names to ensure uniqueness"
  type        = string
}

variable "kms_key_arn" {
  description = "ARN of the KMS key for encryption"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for Kendra connector"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for Kendra VPC configuration"
  type        = list(string)
}

variable "kendra_security_group_id" {
  description = "Security group ID for Kendra connector"
  type        = string
}

variable "sharepoint_urls" {
  description = "List of SharePoint site URLs to crawl"
  type        = list(string)
  default     = []
}

variable "jwt_key_url" {
  description = "URL for JWT key validation (for user token authentication)"
  type        = string
  default     = "https://login.microsoftonline.com/common/discovery/v2.0/keys"
}