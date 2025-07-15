output "api_gateway_url" {
  value       = "https://${aws_api_gateway_rest_api.orchestration_api.id}.execute-api.us-east-1.amazonaws.com/prod/query"
  description = "Private Orchestration API endpoint URL (VPC-only access)"
}

output "api_gateway_id" {
  value       = aws_api_gateway_rest_api.orchestration_api.id
  description = "API Gateway REST API ID"
}

output "lambda_function_name" {
  value       = aws_lambda_function.orchestration_api.function_name
  description = "Name of the orchestration API Lambda function"
}

output "iam_role_arn" {
  value       = aws_iam_role.orchestration_api_role.arn
  description = "ARN of the orchestration API IAM role"
}