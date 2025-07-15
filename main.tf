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

# S3 bucket for PDF documents with CIS compliance
resource "awscc_s3_bucket" "pdf_documents" {
  bucket_name = "pdf-splitter-documents-${random_id.bucket_suffix.hex}"
  
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
  
  # CIS 2.1.3 - Enable MFA delete (Note: This requires root user to enable)
  # mfa_delete = "Enabled"  # Commented as it requires root user
  
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
  bucket_name = "pdf-splitter-access-logs-${random_id.bucket_suffix.hex}"
  
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

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# IAM role for Lambda function
resource "awscc_iam_role" "lambda_role" {
  role_name = "pdf-splitter-lambda-role"
  assume_role_policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
  
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  ]
  
  policies = [
    {
      policy_name = "S3Access"
      policy_document = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Allow"
            Action = [
              "s3:GetObject",
              "s3:PutObject",
              "s3:DeleteObject"
            ]
            Resource = "${awscc_s3_bucket.pdf_documents.arn}/*"
          }
        ]
      })
    },
    {
      policy_name = "KMSAccess"
      policy_document = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Allow"
            Action = [
              "kms:Decrypt",
              "kms:DescribeKey"
            ]
            Resource = aws_kms_key.lambda_env_key.arn
          }
        ]
      })
    },
    {
      policy_name = "SQSAccess"
      policy_document = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Allow"
            Action = [
              "sqs:SendMessage"
            ]
            Resource = aws_sqs_queue.lambda_dlq.arn
          }
        ]
      })
    },
    {
      policy_name = "XRayAccess"
      policy_document = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Allow"
            Action = [
              "xray:PutTraceSegments",
              "xray:PutTelemetryRecords"
            ]
            Resource = "*"
          }
        ]
      })
    }
  ]
  
  tags = [
    {
      key   = "Purpose"
      value = "PDF Splitter Lambda Role"
    }
  ]
}

# KMS key for Lambda environment encryption (CIS compliance)
resource "aws_kms_key" "lambda_env_key" {
  description             = "KMS key for Lambda environment variable encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow Lambda service to use the key"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "lambda-env-encryption-key"
    Purpose     = "Lambda Environment Encryption"
    Compliance  = "CIS"
  }
}

resource "aws_kms_alias" "lambda_env_key_alias" {
  name          = "alias/lambda-env-encryption"
  target_key_id = aws_kms_key.lambda_env_key.key_id
}

data "aws_caller_identity" "current" {}

# Lambda function with CIS compliance
resource "awscc_lambda_function" "pdf_splitter" {
  function_name = "pdf-splitter-function"
  runtime       = "python3.11"
  handler       = "lambda_function.lambda_handler"
  role          = awscc_iam_role.lambda_role.arn
  timeout       = 300
  memory_size   = 1024
  
  # CIS 3.1 - Enable environment variable encryption
  kms_key_arn = aws_kms_key.lambda_env_key.arn
  
  code = {
    zip_file = data.archive_file.lambda_zip.output_base64
  }
  
  environment = {
    variables = {
      S3_BUCKET = awscc_s3_bucket.pdf_documents.bucket_name
    }
  }
  
  # CIS 3.2 - Enable tracing
  tracing_config = {
    mode = "Active"
  }
  
  # CIS 3.3 - Enable dead letter queue
  dead_letter_config = {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }
  
  tags = [
    {
      key   = "Purpose"
      value = "PDF Document Splitter"
    },
    {
      key   = "Compliance"
      value = "CIS"
    }
  ]
}

# Dead Letter Queue for Lambda (CIS compliance)
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "pdf-splitter-dlq"
  message_retention_seconds = 1209600 # 14 days
  
  # Enable encryption
  kms_master_key_id = aws_kms_key.lambda_env_key.arn
  
  tags = {
    Name       = "pdf-splitter-dlq"
    Purpose    = "Lambda Dead Letter Queue"
    Compliance = "CIS"
  }
}

# Create the Lambda function code
resource "local_file" "lambda_code" {
  filename = "${path.module}/lambda_function.py"
  content = file("${path.module}/lambda_function.py")
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = local_file.lambda_code.filename
  output_path = "${path.module}/lambda_function.zip"
  depends_on  = [local_file.lambda_code]
}

# S3 bucket notification to trigger Lambda
resource "aws_s3_bucket_notification" "pdf_upload_notification" {
  bucket = awscc_s3_bucket.pdf_documents.bucket_name

  lambda_function {
    lambda_function_arn = awscc_lambda_function.pdf_splitter.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "input/"
    filter_suffix       = ".pdf"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = awscc_lambda_function.pdf_splitter.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = awscc_s3_bucket.pdf_documents.arn
}

# CloudWatch Log Group for Lambda (CIS compliance)
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${awscc_lambda_function.pdf_splitter.function_name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.lambda_env_key.arn

  tags = {
    Name       = "pdf-splitter-lambda-logs"
    Purpose    = "Lambda Function Logs"
    Compliance = "CIS"
  }
}

# CloudWatch Alarms for monitoring (CIS compliance)
resource "aws_cloudwatch_metric_alarm" "lambda_error_rate" {
  alarm_name          = "pdf-splitter-lambda-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "This metric monitors lambda error rate"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = awscc_lambda_function.pdf_splitter.function_name
  }

  tags = {
    Name       = "lambda-error-alarm"
    Compliance = "CIS"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  alarm_name          = "pdf-splitter-lambda-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Average"
  threshold           = "240000" # 4 minutes (80% of 5-minute timeout)
  alarm_description   = "This metric monitors lambda execution duration"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = awscc_lambda_function.pdf_splitter.function_name
  }

  tags = {
    Name       = "lambda-duration-alarm"
    Compliance = "CIS"
  }
}

# SNS Topic for alerts (CIS compliance)
resource "aws_sns_topic" "alerts" {
  name              = "pdf-splitter-alerts"
  kms_master_key_id = aws_kms_key.lambda_env_key.arn

  tags = {
    Name       = "pdf-splitter-alerts"
    Purpose    = "Security and Performance Alerts"
    Compliance = "CIS"
  }
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

# Outputs
output "s3_bucket_name" {
  value       = awscc_s3_bucket.pdf_documents.bucket_name
  description = "Name of the S3 bucket for PDF documents"
}

output "lambda_function_name" {
  value       = awscc_lambda_function.pdf_splitter.function_name
  description = "Name of the Lambda function"
}

output "access_logs_bucket_name" {
  value       = awscc_s3_bucket.access_logs.bucket_name
  description = "Name of the S3 access logs bucket"
}

output "kms_key_id" {
  value       = aws_kms_key.lambda_env_key.key_id
  description = "KMS key ID used for encryption"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "SNS topic ARN for alerts"
}
