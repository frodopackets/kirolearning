output "pdf_documents_bucket_name" {
  value       = awscc_s3_bucket.pdf_documents.bucket_name
  description = "Name of the S3 bucket for PDF documents"
}

output "pdf_documents_bucket_arn" {
  value       = awscc_s3_bucket.pdf_documents.arn
  description = "ARN of the S3 bucket for PDF documents"
}

output "access_logs_bucket_name" {
  value       = awscc_s3_bucket.access_logs.bucket_name
  description = "Name of the S3 access logs bucket"
}

output "access_logs_bucket_arn" {
  value       = awscc_s3_bucket.access_logs.arn
  description = "ARN of the S3 access logs bucket"
}