# ============================================================================
# ORCHESTRATION API MODULE - API Gateway + Lambda for Knowledge Base queries
# ============================================================================

# IAM role for Orchestration API Lambda
resource "aws_iam_role" "orchestration_api_role" {
  name = "orchestration-api-role-${var.bucket_suffix}"

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
    Name       = "orchestration-api-role"
    Purpose    = "Orchestration API Lambda Role"
    Compliance = "CIS"
  }
}

# IAM policy for Orchestration API (with VPC permissions)
resource "aws_iam_role_policy" "orchestration_api_policy" {
  name = "orchestration-api-policy"
  role = aws_iam_role.orchestration_api_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate"
        ]
        Resource = [
          var.knowledge_base_arn,
          "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = var.opensearch_collection_arn
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
      },
      {
        Effect = "Allow"
        Action = [
          "kendra:Query",
          "kendra:DescribeIndex",
          "kendra:ListDataSources"
        ]
        Resource = var.kendra_index_id != "" ? "arn:aws:kendra:us-east-1:*:index/${var.kendra_index_id}" : "*"
      }
    ]
  })
}

# Orchestration API Lambda function (VPC-enabled)
resource "aws_lambda_function" "orchestration_api" {
  filename         = var.lambda_zip_path
  function_name    = "orchestration-api-${var.bucket_suffix}"
  role            = aws_iam_role.orchestration_api_role.arn
  handler         = "orchestration_api.lambda_handler"
  runtime         = "python3.11"
  timeout         = 30
  memory_size     = 512

  # VPC configuration for private networking
  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  environment {
    variables = {
      KNOWLEDGE_BASE_ID = var.knowledge_base_id
      OPENSEARCH_ENDPOINT = var.opensearch_collection_endpoint
      KENDRA_INDEX_ID = var.kendra_index_id
      ENABLE_SHAREPOINT_SEARCH = "true"
      ENABLE_PROMPT_CACHING = "true"
      CACHE_TTL_MINUTES = "60"
    }
  }

  kms_key_arn = var.kms_key_arn

  tracing_config {
    mode = "Active"
  }

  tags = {
    Name       = "orchestration-api-private"
    Purpose    = "Private Knowledge Base Orchestration API"
    Compliance = "CIS"
  }
}

# API Gateway for Orchestration API (Private)
resource "aws_api_gateway_rest_api" "orchestration_api" {
  name        = "orchestration-api-${var.bucket_suffix}"
  description = "Private Orchestration API for Bedrock Knowledge Base with metadata filtering"

  endpoint_configuration {
    types            = ["PRIVATE"]
    vpc_endpoint_ids = [var.api_gateway_vpc_endpoint_id]
  }

  # Resource policy to restrict access to VPC endpoint only
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = "execute-api:Invoke"
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:sourceVpce" = var.api_gateway_vpc_endpoint_id
          }
        }
      }
    ]
  })

  tags = {
    Name       = "orchestration-api-private"
    Purpose    = "Private Knowledge Base API Gateway"
    Compliance = "CIS"
  }
}

# API Gateway Resource
resource "aws_api_gateway_resource" "query" {
  rest_api_id = aws_api_gateway_rest_api.orchestration_api.id
  parent_id   = aws_api_gateway_rest_api.orchestration_api.root_resource_id
  path_part   = "query"
}

# API Gateway Method
resource "aws_api_gateway_method" "query_post" {
  rest_api_id   = aws_api_gateway_rest_api.orchestration_api.id
  resource_id   = aws_api_gateway_resource.query.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

# API Gateway Integration
resource "aws_api_gateway_integration" "query_integration" {
  rest_api_id = aws_api_gateway_rest_api.orchestration_api.id
  resource_id = aws_api_gateway_resource.query.id
  http_method = aws_api_gateway_method.query_post.http_method

  integration_http_method = "POST"
  type                   = "AWS_PROXY"
  uri                    = aws_lambda_function.orchestration_api.invoke_arn
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orchestration_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.orchestration_api.execution_arn}/*/*"
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "orchestration_api" {
  depends_on = [
    aws_api_gateway_method.query_post,
    aws_api_gateway_integration.query_integration
  ]

  rest_api_id = aws_api_gateway_rest_api.orchestration_api.id
  stage_name  = "prod"

  lifecycle {
    create_before_destroy = true
  }
}

# CloudWatch Log Group for Orchestration API
resource "aws_cloudwatch_log_group" "orchestration_api_logs" {
  name              = "/aws/lambda/${aws_lambda_function.orchestration_api.function_name}"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn

  tags = {
    Name       = "orchestration-api-logs"
    Purpose    = "Orchestration API Logs"
    Compliance = "CIS"
  }
}