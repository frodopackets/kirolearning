# ============================================================================
# SHAREPOINT SYNC MODULE - Sync SharePoint content to Bedrock Knowledge Base
# ============================================================================

# IAM role for SharePoint sync Lambda
resource "aws_iam_role" "sharepoint_sync_role" {
  name = "sharepoint-sync-lambda-role-${var.bucket_suffix}"

  assume_role_policy = jsonencode({
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

  tags = {
    Name       = "sharepoint-sync-lambda-role"
    Purpose    = "SharePoint to Bedrock Sync Role"
    Compliance = "CIS"
  }
}

# IAM policy for SharePoint sync Lambda
resource "aws_iam_role_policy" "sharepoint_sync_policy" {
  name = "sharepoint-sync-policy"
  role = aws_iam_role.sharepoint_sync_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kendra:Query",
          "kendra:DescribeIndex",
          "kendra:ListDataSources",
          "kendra:BatchGetDocumentStatus"
        ]
        Resource = var.kendra_index_arn
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:StartIngestionJob",
          "bedrock:GetIngestionJob",
          "bedrock:ListIngestionJobs"
        ]
        Resource = var.knowledge_base_arn
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          var.sharepoint_credentials_secret_arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DetachNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# SharePoint sync Lambda function
resource "aws_lambda_function" "sharepoint_sync" {
  filename         = var.lambda_zip_path
  function_name    = "sharepoint-sync-${var.bucket_suffix}"
  role            = aws_iam_role.sharepoint_sync_role.arn
  handler         = "sharepoint_sync.lambda_handler"
  runtime         = "python3.11"
  timeout         = 900  # 15 minutes for large sync operations
  memory_size     = 1024

  # VPC configuration for private access
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  environment {
    variables = {
      KENDRA_INDEX_ID = var.kendra_index_id
      KNOWLEDGE_BASE_ID = var.knowledge_base_id
      S3_BUCKET = var.s3_bucket_name
      SHAREPOINT_CREDENTIALS_SECRET_ARN = var.sharepoint_credentials_secret_arn
      SYNC_PREFIX = "sharepoint-content"
    }
  }

  kms_key_arn = var.kms_key_arn

  tracing_config {
    mode = "Active"
  }

  tags = {
    Name       = "sharepoint-sync"
    Purpose    = "SharePoint to Bedrock Knowledge Base Sync"
    Compliance = "CIS"
  }
}

# EventBridge rule to trigger sync on schedule
resource "aws_cloudwatch_event_rule" "sharepoint_sync_schedule" {
  name                = "sharepoint-sync-schedule-${var.bucket_suffix}"
  description         = "Trigger SharePoint sync to Bedrock Knowledge Base"
  schedule_expression = "cron(0 2 * * ? *)"  # Daily at 2 AM UTC

  tags = {
    Name    = "sharepoint-sync-schedule"
    Purpose = "SharePoint Sync Scheduler"
  }
}

# EventBridge target for Lambda
resource "aws_cloudwatch_event_target" "sharepoint_sync_target" {
  rule      = aws_cloudwatch_event_rule.sharepoint_sync_schedule.name
  target_id = "SharePointSyncTarget"
  arn       = aws_lambda_function.sharepoint_sync.arn
}

# Lambda permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sharepoint_sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sharepoint_sync_schedule.arn
}

# CloudWatch Log Group for SharePoint sync Lambda
resource "aws_cloudwatch_log_group" "sharepoint_sync_logs" {
  name              = "/aws/lambda/${aws_lambda_function.sharepoint_sync.function_name}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn

  tags = {
    Name       = "sharepoint-sync-logs"
    Purpose    = "SharePoint Sync Lambda Logs"
    Compliance = "CIS"
  }
}

# CloudWatch alarm for sync failures
resource "aws_cloudwatch_metric_alarm" "sharepoint_sync_errors" {
  alarm_name          = "sharepoint-sync-errors-${var.bucket_suffix}"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "This metric monitors SharePoint sync errors"
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    FunctionName = aws_lambda_function.sharepoint_sync.function_name
  }

  tags = {
    Name       = "sharepoint-sync-error-alarm"
    Compliance = "CIS"
  }
}