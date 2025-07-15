output "vpc_id" {
  value       = aws_vpc.main.id
  description = "ID of the VPC"
}

output "vpc_cidr_block" {
  value       = aws_vpc.main.cidr_block
  description = "CIDR block of the VPC"
}

output "public_subnet_ids" {
  value       = aws_subnet.public[*].id
  description = "IDs of the public subnets"
}

output "private_subnet_ids" {
  value       = aws_subnet.private[*].id
  description = "IDs of the private subnets"
}

output "lambda_security_group_id" {
  value       = aws_security_group.lambda.id
  description = "ID of the Lambda security group"
}

output "vpc_endpoints_security_group_id" {
  value       = aws_security_group.vpc_endpoints.id
  description = "ID of the VPC endpoints security group"
}

output "api_gateway_vpc_endpoint_id" {
  value       = aws_vpc_endpoint.api_gateway.id
  description = "ID of the API Gateway VPC endpoint"
}

output "api_gateway_vpc_endpoint_dns_names" {
  value       = aws_vpc_endpoint.api_gateway.dns_entry[*].dns_name
  description = "DNS names of the API Gateway VPC endpoint"
}