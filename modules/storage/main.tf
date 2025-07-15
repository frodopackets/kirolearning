# ============================================================================
# S3 STORAGE MODULE - Document storage with CIS compliance
# ============================================================================

# S3 bucket for PDF documents with CIS compliance
resource "awscc_s3_bucket" "pdf_documents" {
  bucket_name = "pdf-splitter-documents-${var.bucket_suffix}"
  
  # CIS 2.1.1 - Enable versioning
  versioning_configuration = {
    status = "Enabled"
  }
  
  # CIS 2.1.2 - Enable server-side encryption
  bucket_encryption = {
    server_side_encryption_configuration = [
      {
        server_side_encryption_by_default = {
          sse_algorithm = "AES256"
        }
        bucket_key_enabled = true
      }
    ]
  }
  
  # CIS 2.1.4 - Enable access logging
  logging_configuration = {
    destination_bucket_name = awscc_s3_bucket.access_logs.bucket_name
    log_file_prefix        = "pdf-documents-access-logs/"
  }
  
  # CIS 2.1.5 - Block public access
  public_access_block_configuration = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
  
  tags = [
    {
      key   = "Purpose"
      value = "PDF Document Processing"
    },
    {
      key   = "Compliance"
      value = "CIS"
    }
  ]
}

# Separate bucket for access logs (CIS requirement)
resource "awscc_s3_bucket" "access_logs" {
  bucket_name = "pdf-splitter-access-logs-${var.bucket_suffix}"
  
  # Block public access for logs bucket
  public_access_block_configuration = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
  
  # Encrypt access logs
  bucket_encryption = {
    server_side_encryption_configuration = [
      {
        server_side_encryption_by_default = {
          sse_algorithm = "AES256"
        }
        bucket_key_enabled = true
      }
    ]
  }
  
  tags = [
    {
      key   = "Purpose"
      value = "S3 Access Logs"
    },
    {
      key   = "Compliance"
      value = "CIS"
    }
  ]
}

# S3 Bucket Policy to enforce secure transport (CIS 2.1.6)
resource "aws_s3_bucket_policy" "pdf_documents_policy" {
  bucket = awscc_s3_bucket.pdf_documents.bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureConnections"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          awscc_s3_bucket.pdf_documents.arn,
          "${awscc_s3_bucket.pdf_documents.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "access_logs_policy" {
  bucket = awscc_s3_bucket.access_logs.bucket_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureConnections"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          awscc_s3_bucket.access_logs.arn,
          "${awscc_s3_bucket.access_logs.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}