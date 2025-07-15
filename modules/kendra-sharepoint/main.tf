# ============================================================================
# KENDRA WITH SHAREPOINT CONNECTOR MODULE
# ============================================================================

# IAM role for Kendra service
resource "aws_iam_role" "kendra_role" {
  name = "kendra-sharepoint-role-${var.bucket_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "kendra.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name       = "kendra-sharepoint-role"
    Purpose    = "Kendra SharePoint Service Role"
    Compliance = "CIS"
  }
}

# IAM policy for Kendra service
resource "aws_iam_role_policy" "kendra_policy" {
  name = "kendra-sharepoint-policy"
  role = aws_iam_role.kendra_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = "AWS/Kendra"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup"
        ]
        Resource = "arn:aws:logs:us-east-1:*:log-group:/aws/kendra/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:DescribeLogStreams",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:us-east-1:*:log-group:/aws/kendra/*:log-stream:*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.sharepoint_credentials.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = var.kms_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.us-east-1.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Secrets Manager secret for SharePoint credentials
resource "aws_secretsmanager_secret" "sharepoint_credentials" {
  name                    = "kendra-sharepoint-credentials-${var.bucket_suffix}"
  description             = "SharePoint Online credentials for Kendra connector"
  kms_key_id             = var.kms_key_arn
  recovery_window_in_days = 7

  tags = {
    Name       = "kendra-sharepoint-credentials"
    Purpose    = "SharePoint Connector Credentials"
    Compliance = "CIS"
  }
}

# Placeholder secret version (to be updated with actual credentials)
resource "aws_secretsmanager_secret_version" "sharepoint_credentials" {
  secret_id = aws_secretsmanager_secret.sharepoint_credentials.id
  secret_string = jsonencode({
    username = "PLACEHOLDER_USERNAME"
    password = "PLACEHOLDER_PASSWORD"
    domain   = "PLACEHOLDER_DOMAIN"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Kendra Index for SharePoint content
resource "aws_kendra_index" "sharepoint_index" {
  name        = "sharepoint-knowledge-index-${var.bucket_suffix}"
  description = "Kendra index for SharePoint Online content with ACL-based access control"
  edition     = "DEVELOPER_EDITION"  # Change to ENTERPRISE_EDITION for production
  role_arn    = aws_iam_role.kendra_role.arn

  # Enable user context for ACL-based filtering
  user_context_policy = "USER_TOKEN"

  # User token configurations for SharePoint ACLs
  user_token_configurations {
    jwt_token_type_configuration {
      key_location     = "URL"
      url              = var.jwt_key_url
      secret_manager_arn = aws_secretsmanager_secret.jwt_signing_key.arn
      user_name_attribute_field = "preferred_username"
      group_attribute_field     = "groups"
    }
  }

  # Server-side encryption
  server_side_encryption_configuration {
    kms_key_id = var.kms_key_arn
  }

  tags = {
    Name       = "sharepoint-knowledge-index"
    Purpose    = "SharePoint Content Index"
    Compliance = "CIS"
  }
}

# JWT signing key secret for user token authentication
resource "aws_secretsmanager_secret" "jwt_signing_key" {
  name                    = "kendra-jwt-signing-key-${var.bucket_suffix}"
  description             = "JWT signing key for Kendra user token authentication"
  kms_key_id             = var.kms_key_arn
  recovery_window_in_days = 7

  tags = {
    Name       = "kendra-jwt-signing-key"
    Purpose    = "JWT Token Signing"
    Compliance = "CIS"
  }
}

# Placeholder JWT signing key (to be updated with actual key)
resource "aws_secretsmanager_secret_version" "jwt_signing_key" {
  secret_id = aws_secretsmanager_secret.jwt_signing_key.id
  secret_string = jsonencode({
    key = "PLACEHOLDER_JWT_SIGNING_KEY"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# SharePoint Online Data Source
resource "aws_kendra_data_source" "sharepoint_connector" {
  index_id    = aws_kendra_index.sharepoint_index.id
  name        = "sharepoint-online-connector"
  type        = "SHAREPOINT"
  description = "SharePoint Online connector with ACL synchronization"
  role_arn    = aws_iam_role.kendra_role.arn

  configuration {
    sharepoint_configuration {
      sharepoint_version = "SHAREPOINT_ONLINE"
      
      urls = var.sharepoint_urls
      
      secret_arn = aws_secretsmanager_secret.sharepoint_credentials.arn
      
      # Enable crawling of SharePoint pages
      crawl_attachments                = false  # Focus on pages, not attachments
      use_change_log                  = true   # Incremental sync
      disable_local_groups            = false  # Include local SharePoint groups
      
      # Field mappings for metadata
      field_mappings {
        data_source_field_name = "Author"
        date_field_format     = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        index_field_name      = "sharepoint_author"
      }
      
      field_mappings {
        data_source_field_name = "Created"
        date_field_format     = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        index_field_name      = "sharepoint_created"
      }
      
      field_mappings {
        data_source_field_name = "Modified"
        date_field_format     = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        index_field_name      = "sharepoint_modified"
      }
      
      field_mappings {
        data_source_field_name = "Title"
        index_field_name      = "sharepoint_title"
      }
      
      # ACL configuration - this is key for access control
      access_control_list_configuration {
        key_path = "sharepoint_acl"  # Field containing ACL information
      }
      
      # VPC configuration for private access
      vpc_configuration {
        subnet_ids         = var.private_subnet_ids
        security_group_ids = [var.kendra_security_group_id]
      }
    }
  }

  # Schedule for regular synchronization
  schedule = "cron(0 6 * * ? *)"  # Daily at 6 AM UTC

  tags = {
    Name    = "sharepoint-online-connector"
    Purpose = "SharePoint Content Sync"
  }
}

# CloudWatch Log Group for Kendra
resource "aws_cloudwatch_log_group" "kendra_logs" {
  name              = "/aws/kendra/sharepoint-index-${var.bucket_suffix}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn

  tags = {
    Name       = "kendra-sharepoint-logs"
    Purpose    = "Kendra SharePoint Logs"
    Compliance = "CIS"
  }
}

# Security group for Kendra VPC access
resource "aws_security_group" "kendra" {
  name_prefix = "kendra-sharepoint-${var.bucket_suffix}"
  vpc_id      = var.vpc_id
  description = "Security group for Kendra SharePoint connector"

  egress {
    description = "HTTPS to SharePoint Online"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP to SharePoint Online"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "kendra-sharepoint-sg"
    Purpose    = "Kendra SharePoint Security Group"
    Compliance = "CIS"
  }
}