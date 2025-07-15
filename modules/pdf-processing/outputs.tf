output "lambda_function_name" {
  value       = awscc_lambda_function.pdf_splitter.function_name
  description = "Name of the PDF splitter Lambda function"
}

output "lambda_function_arn" {
  value       = awscc_lambda_function.pdf_splitter.arn
  description = "ARN of the PDF splitter Lambda function"
}