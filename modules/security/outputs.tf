output "kms_key_arn" {
  value       = aws_kms_key.lambda_env_key.arn
  description = "ARN of the KMS key for encryption"
}

output "kms_key_id" {
  value       = aws_kms_key.lambda_env_key.key_id
  description = "ID of the KMS key for encryption"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "ARN of the SNS topic for alerts"
}

output "lambda_dlq_arn" {
  value       = aws_sqs_queue.lambda_dlq.arn
  description = "ARN of the Lambda dead letter queue"
}