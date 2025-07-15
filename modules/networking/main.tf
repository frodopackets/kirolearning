# ============================================================================
# NETWORKING MODULE - VPC infrastructure for private API Gateway
# ============================================================================

# VPC for private networking
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name       = "rag-pipeline-vpc-${var.bucket_suffix}"
    Purpose    = "RAG Pipeline VPC"
    Compliance = "CIS"
  }
}

# Internet Gateway for public subnets
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name       = "rag-pipeline-igw-${var.bucket_suffix}"
    Purpose    = "Internet Gateway"
    Compliance = "CIS"
  }
}

# Public subnets for NAT gateways and VPC endpoints
resource "aws_subnet" "public" {
  count = length(var.availability_zones)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name       = "rag-pipeline-public-subnet-${count.index + 1}-${var.bucket_suffix}"
    Type       = "Public"
    Purpose    = "Public Subnet for NAT and VPC Endpoints"
    Compliance = "CIS"
  }
}

# Private subnets for Lambda functions and internal resources
resource "aws_subnet" "private" {
  count = length(var.availability_zones)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name       = "rag-pipeline-private-subnet-${count.index + 1}-${var.bucket_suffix}"
    Type       = "Private"
    Purpose    = "Private Subnet for Lambda and Internal Resources"
    Compliance = "CIS"
  }
}

# Elastic IPs for NAT Gateways
resource "aws_eip" "nat" {
  count = length(var.availability_zones)

  domain = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name       = "rag-pipeline-nat-eip-${count.index + 1}-${var.bucket_suffix}"
    Purpose    = "NAT Gateway EIP"
    Compliance = "CIS"
  }
}

# NAT Gateways for private subnet internet access
resource "aws_nat_gateway" "main" {
  count = length(var.availability_zones)

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]

  tags = {
    Name       = "rag-pipeline-nat-${count.index + 1}-${var.bucket_suffix}"
    Purpose    = "NAT Gateway"
    Compliance = "CIS"
  }
}

# Route table for public subnets
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name       = "rag-pipeline-public-rt-${var.bucket_suffix}"
    Type       = "Public"
    Purpose    = "Public Route Table"
    Compliance = "CIS"
  }
}

# Route tables for private subnets
resource "aws_route_table" "private" {
  count = length(var.availability_zones)

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name       = "rag-pipeline-private-rt-${count.index + 1}-${var.bucket_suffix}"
    Type       = "Private"
    Purpose    = "Private Route Table"
    Compliance = "CIS"
  }
}

# Associate public subnets with public route table
resource "aws_route_table_association" "public" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Associate private subnets with private route tables
resource "aws_route_table_association" "private" {
  count = length(var.availability_zones)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "rag-pipeline-vpc-endpoints-${var.bucket_suffix}"
  vpc_id      = aws_vpc.main.id
  description = "Security group for VPC endpoints"

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "rag-pipeline-vpc-endpoints-sg-${var.bucket_suffix}"
    Purpose    = "VPC Endpoints Security Group"
    Compliance = "CIS"
  }
}

# Security group for Lambda functions
resource "aws_security_group" "lambda" {
  name_prefix = "rag-pipeline-lambda-${var.bucket_suffix}"
  vpc_id      = aws_vpc.main.id
  description = "Security group for Lambda functions"

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name       = "rag-pipeline-lambda-sg-${var.bucket_suffix}"
    Purpose    = "Lambda Security Group"
    Compliance = "CIS"
  }
}

# VPC Endpoint for API Gateway
resource "aws_vpc_endpoint" "api_gateway" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.execute-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "execute-api:Invoke"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name       = "rag-pipeline-api-gateway-endpoint-${var.bucket_suffix}"
    Purpose    = "API Gateway VPC Endpoint"
    Compliance = "CIS"
  }
}

# VPC Endpoint for S3
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private[*].id)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name       = "rag-pipeline-s3-endpoint-${var.bucket_suffix}"
    Purpose    = "S3 VPC Endpoint"
    Compliance = "CIS"
  }
}

# VPC Endpoint for Bedrock
resource "aws_vpc_endpoint" "bedrock" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:Retrieve",
          "bedrock:RetrieveAndGenerate"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name       = "rag-pipeline-bedrock-endpoint-${var.bucket_suffix}"
    Purpose    = "Bedrock VPC Endpoint"
    Compliance = "CIS"
  }
}

# VPC Endpoint for Bedrock Agent
resource "aws_vpc_endpoint" "bedrock_agent" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-agent-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = [
          "bedrock-agent:*"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name       = "rag-pipeline-bedrock-agent-endpoint-${var.bucket_suffix}"
    Purpose    = "Bedrock Agent VPC Endpoint"
    Compliance = "CIS"
  }
}