# ============================================================================
# SECURITY MODULE - KMS keys, IAM roles, and security policies
# ============================================================================

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
          AWS = "arn:aws:iam::${var.account_id}:root"
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