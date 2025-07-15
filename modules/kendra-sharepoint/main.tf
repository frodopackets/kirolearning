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

# SharePoint Online Data Source V2 (Template-based)
resource "aws_kendra_data_source" "sharepoint_connector" {
  index_id    = aws_kendra_index.sharepoint_index.id
  name        = "sharepoint-online-connector-v2"
  type        = "TEMPLATE"
  description = "SharePoint Online connector V2 with enhanced ACL synchronization using template configuration"
  role_arn    = aws_iam_role.kendra_role.arn

  configuration {
    template_configuration {
      template {
        # SharePoint Connector V2 Template
        template_name = "SharePointOnlineV2"
        template_version = "2.0"
        
        # V2 Template Configuration
        template_parameters = {
          # Connection Configuration
          "sharePointUrls" = jsonencode(var.sharepoint_urls)
          "secretArn" = aws_secretsmanager_secret.sharepoint_credentials.arn
          "authenticationType" = "HTTP_BASIC"
          
          # V2 Enhanced Crawling Configuration
          "crawlAttachments" = "false"
          "useChangeLog" = "true"
          "disableLocalGroups" = "false"
          "enableAclV2" = "true"  # V2 Enhanced ACL processing
          
          # V2 Enhanced Field Mappings
          "fieldMappings" = jsonencode([
            {
              "dataSourceFieldName" = "Author"
              "dateFieldFormat" = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
              "indexFieldName" = "sharepoint_author"
            },
            {
              "dataSourceFieldName" = "Created"
              "dateFieldFormat" = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
              "indexFieldName" = "sharepoint_created"
            },
            {
              "dataSourceFieldName" = "Modified"
              "dateFieldFormat" = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
              "indexFieldName" = "sharepoint_modified"
            },
            {
              "dataSourceFieldName" = "Title"
              "indexFieldName" = "sharepoint_title"
            },
            {
              "dataSourceFieldName" = "ContentType"
              "indexFieldName" = "sharepoint_content_type"
            },
            {
              "dataSourceFieldName" = "FileExtension"
              "indexFieldName" = "sharepoint_file_extension"
            },
            {
              "dataSourceFieldName" = "SiteUrl"
              "indexFieldName" = "sharepoint_site_url"
            },
            {
              "dataSourceFieldName" = "WebUrl"
              "indexFieldName" = "sharepoint_web_url"
            }
          ])
          
          # V2 Enhanced ACL Configuration
          "aclConfiguration" = jsonencode({
            "keyPath" = "sharepoint_acl_v2"
            "enableInheritanceTracking" = true
            "enablePermissionLevelTracking" = true
            "enablePrincipalTypeTracking" = true
          })
          
          # V2 Enhanced Content Filtering
          "inclusionPatterns" = jsonencode([
            "*/SitePages/*",
            "*/Lists/*", 
            "*/Shared Documents/*"
          ])
          
          "exclusionPatterns" = jsonencode([
            "*/Forms/*",
            "*/Style Library/*",
            "*/_catalogs/*",
            "*/bin/*"
          ])
          
          # V2 VPC Configuration
          "vpcConfiguration" = jsonencode({
            "subnetIds" = var.private_subnet_ids
            "securityGroupIds" = [var.kendra_security_group_id]
          })
          
          # V2 Enhanced Sync Configuration
          "syncMode" = "INCREMENTAL"
          "maxConcurrentConnections" = "10"
          "requestTimeout" = "300"
          "retryAttempts" = "3"
        }
      }
    }
  }

  # V2 Enhanced scheduling
  schedule = "cron(0 6 * * ? *)"  # Daily at 6 AM UTC

  tags = {
    Name    = "sharepoint-online-connector-v2"
    Purpose = "SharePoint Content Sync V2"
    Version = "V2"
    Type    = "Template"
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