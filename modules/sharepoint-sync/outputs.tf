output "sharepoint_sync_lambda_name" {
  value       = aws_lambda_function.sharepoint_sync.function_name
  description = "Name of the SharePoint sync Lambda function"
}

output "sharepoint_sync_lambda_arn" {
  value       = aws_lambda_function.sharepoint_sync.arn
  description = "ARN of the SharePoint sync Lambda function"
}

output "sync_schedule_rule_name" {
  value       = aws_cloudwatch_event_rule.sharepoint_sync_schedule.name
  description = "Name of the EventBridge rule for SharePoint sync"
}