output "knowledge_base_id" {
  value       = aws_bedrockagent_knowledge_base.pdf_knowledge_base.id
  description = "ID of the Bedrock Knowledge Base"
}

output "knowledge_base_arn" {
  value       = aws_bedrockagent_knowledge_base.pdf_knowledge_base.arn
  description = "ARN of the Bedrock Knowledge Base"
}

output "opensearch_collection_endpoint" {
  value       = aws_opensearchserverless_collection.knowledge_base_collection.collection_endpoint
  description = "OpenSearch Serverless collection endpoint"
}

output "opensearch_collection_arn" {
  value       = aws_opensearchserverless_collection.knowledge_base_collection.arn
  description = "ARN of the OpenSearch Serverless collection"
}