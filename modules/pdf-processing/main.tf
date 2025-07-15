# ============================================================================
# PDF PROCESSING MODULE - Lambda function for PDF splitting
# ============================================================================

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
            Resource = "${var.s3_bucket_arn}/*"
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
            Resource = var.kms_key_arn
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
            Resource = var.lambda_dlq_arn
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

# Lambda function with CIS compliance
resource "awscc_lambda_function" "pdf_splitter" {
  function_name = "pdf-splitter-function"
  runtime       = "python3.11"
  handler       = "lambda_function.lambda_handler"
  role          = awscc_iam_role.lambda_role.arn
  timeout       = 300
  memory_size   = 1024
  
  # CIS 3.1 - Enable environment variable encryption
  kms_key_arn = var.kms_key_arn
  
  code = {
    zip_file = var.lambda_zip_base64
  }
  
  environment = {
    variables = {
      S3_BUCKET = var.s3_bucket_name
    }
  }
  
  # CIS 3.2 - Enable tracing
  tracing_config = {
    mode = "Active"
  }
  
  # CIS 3.3 - Enable dead letter queue
  dead_letter_config = {
    target_arn = var.lambda_dlq_arn
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

# S3 bucket notification to trigger Lambda
resource "aws_s3_bucket_notification" "pdf_upload_notification" {
  bucket = var.s3_bucket_name

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
  source_arn    = var.s3_bucket_arn
}

# CloudWatch Log Group for Lambda (CIS compliance)
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${awscc_lambda_function.pdf_splitter.function_name}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn

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
  alarm_actions       = [var.sns_topic_arn]

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
  alarm_actions       = [var.sns_topic_arn]

  dimensions = {
    FunctionName = awscc_lambda_function.pdf_splitter.function_name
  }

  tags = {
    Name       = "lambda-duration-alarm"
    Compliance = "CIS"
  }
}