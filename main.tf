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
  }
}

provider "awscc" {
  region = "us-east-1"
}

provider "aws" {
  region = "us-east-1"
}

# S3 bucket for PDF documents
resource "awscc_s3_bucket" "pdf_documents" {
  bucket_name = "pdf-splitter-documents-${random_id.bucket_suffix.hex}"
  
  tags = [
    {
      key   = "Purpose"
      value = "PDF Document Processing"
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
    }
  ]
  
  tags = [
    {
      key   = "Purpose"
      value = "PDF Splitter Lambda Role"
    }
  ]
}

# Lambda function
resource "awscc_lambda_function" "pdf_splitter" {
  function_name = "pdf-splitter-function"
  runtime       = "python3.11"
  handler       = "lambda_function.lambda_handler"
  role          = awscc_iam_role.lambda_role.arn
  timeout       = 300
  memory_size   = 1024
  
  code = {
    zip_file = data.archive_file.lambda_zip.output_base64
  }
  
  environment = {
    variables = {
      S3_BUCKET = awscc_s3_bucket.pdf_documents.bucket_name
    }
  }
  
  tags = [
    {
      key   = "Purpose"
      value = "PDF Document Splitter"
    }
  ]
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

# Outputs
output "s3_bucket_name" {
  value = awscc_s3_bucket.pdf_documents.bucket_name
}

output "lambda_function_name" {
  value = awscc_lambda_function.pdf_splitter.function_name
}
