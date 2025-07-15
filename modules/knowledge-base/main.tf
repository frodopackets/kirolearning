# ============================================================================
# KNOWLEDGE BASE MODULE - Bedrock Knowledge Base with OpenSearch
# ============================================================================

# OpenSearch Serverless Collection for vector storage
resource "aws_opensearchserverless_collection" "knowledge_base_collection" {
  name = "bedrock-kb-collection-${var.bucket_suffix}"
  type = "VECTORSEARCH"

  tags = {
    Name       = "bedrock-knowledge-base-collection"
    Purpose    = "Vector Storage for Bedrock Knowledge Base"
    Compliance = "CIS"
  }
}

# OpenSearch Serverless Security Policy
resource "aws_opensearchserverless_security_policy" "kb_encryption_policy" {
  name = "bedrock-kb-encryption-policy-${var.bucket_suffix}"
  type = "encryption"
  policy = jsonencode({
    Rules = [
      {
        Resource = [
          "collection/bedrock-kb-collection-${var.bucket_suffix}"
        ]
        ResourceType = "collection"
      }
    ]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "kb_network_policy" {
  name = "bedrock-kb-network-policy-${var.bucket_suffix}"
  type = "network"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/bedrock-kb-collection-${var.bucket_suffix}"
          ]
          ResourceType = "collection"
        }
      ]
      AllowFromPublic = true
    }
  ])
}

# IAM role for Bedrock Knowledge Base
resource "aws_iam_role" "bedrock_kb_role" {
  name = "bedrock-knowledge-base-role-${var.bucket_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name       = "bedrock-knowledge-base-role"
    Purpose    = "Bedrock Knowledge Base Service Role"
    Compliance = "CIS"
  }
}

# IAM policy for Bedrock Knowledge Base
resource "aws_iam_role_policy" "bedrock_kb_policy" {
  name = "bedrock-knowledge-base-policy"
  role = aws_iam_role.bedrock_kb_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.s3_bucket_arn,
          "${var.s3_bucket_arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "aoss:APIAccessAll"
        ]
        Resource = aws_opensearchserverless_collection.knowledge_base_collection.arn
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel"
        ]
        Resource = "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v1"
      }
    ]
  })
}

# OpenSearch data access policy
resource "aws_opensearchserverless_access_policy" "kb_data_policy" {
  name = "bedrock-kb-data-policy-${var.bucket_suffix}"
  type = "data"
  policy = jsonencode([
    {
      Rules = [
        {
          Resource = [
            "collection/bedrock-kb-collection-${var.bucket_suffix}"
          ]
          Permission = [
            "aoss:CreateCollectionItems",
            "aoss:DeleteCollectionItems",
            "aoss:UpdateCollectionItems",
            "aoss:DescribeCollectionItems"
          ]
          ResourceType = "collection"
        },
        {
          Resource = [
            "index/bedrock-kb-collection-${var.bucket_suffix}/*"
          ]
          Permission = [
            "aoss:CreateIndex",
            "aoss:DeleteIndex",
            "aoss:UpdateIndex",
            "aoss:DescribeIndex",
            "aoss:ReadDocument",
            "aoss:WriteDocument"
          ]
          ResourceType = "index"
        }
      ]
      Principal = [
        aws_iam_role.bedrock_kb_role.arn,
        var.orchestration_api_role_arn
      ]
    }
  ])
}

# Bedrock Knowledge Base
resource "aws_bedrockagent_knowledge_base" "pdf_knowledge_base" {
  name     = "pdf-document-knowledge-base"
  role_arn = aws_iam_role.bedrock_kb_role.arn

  knowledge_base_configuration {
    vector_knowledge_base_configuration {
      embedding_model_arn = "arn:aws:bedrock:us-east-1::foundation-model/amazon.titan-embed-text-v1"
    }
    type = "VECTOR"
  }

  storage_configuration {
    opensearch_serverless_configuration {
      collection_arn    = aws_opensearchserverless_collection.knowledge_base_collection.arn
      vector_index_name = "bedrock-knowledge-base-index"
      field_mapping {
        vector_field   = "bedrock-knowledge-base-default-vector"
        text_field     = "AMAZON_BEDROCK_TEXT_CHUNK"
        metadata_field = "AMAZON_BEDROCK_METADATA"
      }
    }
    type = "OPENSEARCH_SERVERLESS"
  }

  tags = {
    Name       = "pdf-document-knowledge-base"
    Purpose    = "PDF Document Knowledge Base"
    Compliance = "CIS"
  }

  depends_on = [
    aws_opensearchserverless_collection.knowledge_base_collection,
    aws_opensearchserverless_access_policy.kb_data_policy
  ]
}

# Data Source for Knowledge Base
resource "aws_bedrockagent_data_source" "pdf_data_source" {
  knowledge_base_id = aws_bedrockagent_knowledge_base.pdf_knowledge_base.id
  name              = "pdf-documents-data-source"

  data_source_configuration {
    s3_configuration {
      bucket_arn = var.s3_bucket_arn
      inclusion_prefixes = ["processed/", "output/"]
    }
    type = "S3"
  }

  tags = {
    Name    = "pdf-documents-data-source"
    Purpose = "PDF Documents Data Source"
  }
}