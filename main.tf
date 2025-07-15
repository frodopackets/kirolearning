# ============================================================================
# MAIN TERRAFORM CONFIGURATION - CIS-Compliant RAG Pipeline
# ============================================================================

terraform {
  required_providers {
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 0.70.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.4.0"
    }
  }
}

provider "awscc" {
  region = "us-east-1"
}

provider "aws" {
  region = "us-east-1"
}

# Random suffix for unique resource naming
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# ============================================================================
# LAMBDA FUNCTION CODE PREPARATION
# ============================================================================

# Create the Lambda function code files
resource "local_file" "lambda_code" {
  filename = "${path.module}/lambda_function.py"
  content  = file("${path.module}/lambda_function.py")
}

resource "local_file" "orchestration_api_code" {
  filename = "${path.module}/orchestration_api.py"
  content  = file("${path.module}/orchestration_api.py")
}

resource "local_file" "sharepoint_sync_code" {
  filename = "${path.module}/sharepoint_sync.py"
  content  = file("${path.module}/sharepoint_sync.py")
}

# Archive Lambda function code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = local_file.lambda_code.filename
  output_path = "${path.module}/lambda_function.zip"
  depends_on  = [local_file.lambda_code]
}

data "archive_file" "orchestration_api_zip" {
  type        = "zip"
  source_file = local_file.orchestration_api_code.filename
  output_path = "${path.module}/orchestration_api.zip"
  depends_on  = [local_file.orchestration_api_code]
}

data "archive_file" "sharepoint_sync_zip" {
  type        = "zip"
  source_file = local_file.sharepoint_sync_code.filename
  output_path = "${path.module}/sharepoint_sync.zip"
  depends_on  = [local_file.sharepoint_sync_code]
}

# ============================================================================
# MODULE INSTANTIATION
# ============================================================================

# Security module - KMS keys, SNS, SQS
module "security" {
  source     = "./modules/security"
  account_id = data.aws_caller_identity.current.account_id
}

# Networking module - VPC infrastructure for private API Gateway
module "networking" {
  source        = "./modules/networking"
  bucket_suffix = random_id.bucket_suffix.hex
  aws_region    = "us-east-1"
}

# Storage module - S3 buckets with CIS compliance
module "storage" {
  source        = "./modules/storage"
  bucket_suffix = random_id.bucket_suffix.hex
}

# PDF processing module - Lambda function for PDF splitting
module "pdf_processing" {
  source             = "./modules/pdf-processing"
  s3_bucket_name     = module.storage.pdf_documents_bucket_name
  s3_bucket_arn      = module.storage.pdf_documents_bucket_arn
  kms_key_arn        = module.security.kms_key_arn
  lambda_dlq_arn     = module.security.lambda_dlq_arn
  sns_topic_arn      = module.security.sns_topic_arn
  lambda_zip_base64  = data.archive_file.lambda_zip.output_base64
}

# Knowledge Base module - Bedrock Knowledge Base with OpenSearch
module "knowledge_base" {
  source                        = "./modules/knowledge-base"
  bucket_suffix                 = random_id.bucket_suffix.hex
  s3_bucket_arn                 = module.storage.pdf_documents_bucket_arn
  orchestration_api_role_arn    = module.orchestration_api.iam_role_arn
}

# Kendra SharePoint module - SharePoint connector for ACL extraction
module "kendra_sharepoint" {
  source                    = "./modules/kendra-sharepoint"
  bucket_suffix             = random_id.bucket_suffix.hex
  kms_key_arn              = module.security.kms_key_arn
  vpc_id                   = module.networking.vpc_id
  private_subnet_ids       = module.networking.private_subnet_ids
  kendra_security_group_id = module.networking.lambda_security_group_id  # Reuse Lambda security group
  
  # SharePoint configuration (to be updated with actual URLs)
  sharepoint_urls = [
    "https://yourcompany.sharepoint.com/sites/finance",
    "https://yourcompany.sharepoint.com/sites/hr",
    "https://yourcompany.sharepoint.com/sites/legal"
  ]
}

# SharePoint sync module - Sync SharePoint content to Bedrock Knowledge Base
module "sharepoint_sync" {
  source                            = "./modules/sharepoint-sync"
  bucket_suffix                     = random_id.bucket_suffix.hex
  kendra_index_id                   = module.kendra_sharepoint.kendra_index_id
  kendra_index_arn                  = module.kendra_sharepoint.kendra_index_arn
  knowledge_base_id                 = module.knowledge_base.knowledge_base_id
  knowledge_base_arn                = module.knowledge_base.knowledge_base_arn
  s3_bucket_name                    = module.storage.pdf_documents_bucket_name
  s3_bucket_arn                     = module.storage.pdf_documents_bucket_arn
  sharepoint_credentials_secret_arn = module.kendra_sharepoint.sharepoint_credentials_secret_arn
  kms_key_arn                       = module.security.kms_key_arn
  private_subnet_ids                = module.networking.private_subnet_ids
  lambda_security_group_id          = module.networking.lambda_security_group_id
  lambda_zip_path                   = data.archive_file.sharepoint_sync_zip.output_path
  sns_topic_arn                     = module.security.sns_topic_arn
}

# Orchestration API module - Private API Gateway + Lambda for queries
module "orchestration_api" {
  source                          = "./modules/orchestration-api"
  bucket_suffix                   = random_id.bucket_suffix.hex
  knowledge_base_id               = module.knowledge_base.knowledge_base_id
  knowledge_base_arn              = module.knowledge_base.knowledge_base_arn
  opensearch_collection_endpoint  = module.knowledge_base.opensearch_collection_endpoint
  opensearch_collection_arn       = module.knowledge_base.opensearch_collection_arn
  kms_key_arn                     = module.security.kms_key_arn
  lambda_zip_path                 = data.archive_file.orchestration_api_zip.output_path
  private_subnet_ids              = module.networking.private_subnet_ids
  lambda_security_group_id        = module.networking.lambda_security_group_id
  api_gateway_vpc_endpoint_id     = module.networking.api_gateway_vpc_endpoint_id
  kendra_index_id                 = module.kendra_sharepoint.kendra_index_id
}

# ============================================================================
# OUTPUTS
# ============================================================================

output "s3_bucket_name" {
  value       = module.storage.pdf_documents_bucket_name
  description = "Name of the S3 bucket for PDF documents"
}

output "lambda_function_name" {
  value       = module.pdf_processing.lambda_function_name
  description = "Name of the PDF splitter Lambda function"
}

output "access_logs_bucket_name" {
  value       = module.storage.access_logs_bucket_name
  description = "Name of the S3 access logs bucket"
}

output "kms_key_id" {
  value       = module.security.kms_key_id
  description = "KMS key ID used for encryption"
}

output "sns_topic_arn" {
  value       = module.security.sns_topic_arn
  description = "SNS topic ARN for alerts"
}

output "knowledge_base_id" {
  value       = module.knowledge_base.knowledge_base_id
  description = "Bedrock Knowledge Base ID"
}

output "opensearch_collection_endpoint" {
  value       = module.knowledge_base.opensearch_collection_endpoint
  description = "OpenSearch Serverless collection endpoint"
}

output "orchestration_api_url" {
  value       = module.orchestration_api.api_gateway_url
  description = "Private Orchestration API endpoint URL (VPC-only access)"
}

output "vpc_id" {
  value       = module.networking.vpc_id
  description = "VPC ID for private API Gateway access"
}

output "private_subnet_ids" {
  value       = module.networking.private_subnet_ids
  description = "Private subnet IDs where resources can access the API"
}

output "api_gateway_vpc_endpoint_dns" {
  value       = module.networking.api_gateway_vpc_endpoint_dns_names
  description = "DNS names for the API Gateway VPC endpoint"
}

output "kendra_index_id" {
  value       = module.kendra_sharepoint.kendra_index_id
  description = "Kendra index ID for SharePoint content"
}

output "sharepoint_credentials_secret_arn" {
  value       = module.kendra_sharepoint.sharepoint_credentials_secret_arn
  description = "ARN of the SharePoint credentials secret (update with actual credentials)"
}

output "jwt_signing_key_secret_arn" {
  value       = module.kendra_sharepoint.jwt_signing_key_secret_arn
  description = "ARN of the JWT signing key secret (update with actual key)"
}

output "sharepoint_sync_lambda_name" {
  value       = module.sharepoint_sync.sharepoint_sync_lambda_name
  description = "Name of the SharePoint sync Lambda function"
}

output "sync_schedule_rule_name" {
  value       = module.sharepoint_sync.sync_schedule_rule_name
  description = "Name of the EventBridge rule for SharePoint sync scheduling"
}
