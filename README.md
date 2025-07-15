# CIS-Compliant RAG Pipeline with Bedrock Knowledge Base

This project deploys a **complete CIS-compliant RAG (Retrieval-Augmented Generation) pipeline** that processes PDF documents, creates a searchable knowledge base, and provides secure access through metadata filtering. The system automatically splits large PDFs, indexes them in Bedrock Knowledge Base with OpenSearch, and provides an orchestration API for your Streamlit frontend.

## Complete Architecture

### Document Processing Layer
- **PDF Splitter Lambda**: Python 3.11 runtime with PyPDF2 for efficient PDF processing
- **S3 Buckets**: Separate encrypted buckets for documents and access logs
- **Metadata Extraction**: Automatic access control metadata from file paths

### Knowledge Base Layer  
- **Unified Bedrock Knowledge Base**: Single vector store with Amazon Titan embeddings
- **OpenSearch Serverless**: Scalable vector database for all document types
- **SharePoint Content Sync**: Automated sync of SharePoint pages with ACL preservation
- **Unified Search**: Single knowledge base containing both PDFs and SharePoint content
- **Access Control**: Consistent metadata-based filtering for all content types

### Private API Layer
- **Private API Gateway**: VPC-only access with Interface VPC endpoints
- **Lambda in VPC**: Orchestration API runs in private subnets
- **Metadata Filtering**: User/group-based access control
- **Dual Modes**: Document retrieval and RAG generation
- **Prompt Caching**: Claude prompt caching for improved performance and cost reduction

### Network Security
- **VPC Infrastructure**: Private subnets, NAT gateways, and VPC endpoints
- **VPC Endpoints**: Secure access to AWS services without internet routing
- **Security Groups**: Network-level access controls
- **Private DNS**: Internal service discovery

### Security & Compliance
- **KMS Encryption**: Customer-managed keys with automatic rotation
- **IAM Roles**: Least-privilege permissions following CIS guidelines
- **CloudWatch**: Comprehensive monitoring and alerting
- **CIS Compliance**: Full implementation of security benchmarks

## CIS Compliance Features

### S3 Security (CIS 2.1.x)
- ✅ **2.1.1** - S3 bucket versioning enabled
- ✅ **2.1.2** - Server-side encryption with AES-256
- ✅ **2.1.3** - MFA delete ready (requires root user activation)
- ✅ **2.1.4** - Access logging to separate encrypted bucket
- ✅ **2.1.5** - Public access completely blocked
- ✅ **2.1.6** - HTTPS-only access enforced via bucket policy

### Lambda Security (CIS 3.x)
- ✅ **3.1** - Environment variables encrypted with KMS
- ✅ **3.2** - X-Ray tracing enabled for monitoring
- ✅ **3.3** - Dead letter queue configured for error handling

### Encryption & Key Management
- ✅ Customer-managed KMS keys with automatic rotation
- ✅ All data encrypted at rest and in transit
- ✅ Separate encryption for logs, queues, and environment variables

### Monitoring & Alerting
- ✅ CloudWatch log groups with retention policies
- ✅ Performance and error rate alarms
- ✅ SNS notifications for critical events
- ✅ Comprehensive resource tagging for compliance tracking

## Features

- Fast and reliable PDF page counting using PyPDF2
- Splits PDFs exceeding 20 pages into manageable chunks
- Preserves PDFs with ≤20 pages in a processed folder
- Optimized for downstream Bedrock Data Automation processing
- Serverless architecture with automatic scaling
- Enterprise-grade security and compliance controls

## Deployment

1. **Prerequisites**:
   - AWS CLI configured with appropriate permissions
   - Terraform installed

2. **Deploy the infrastructure**:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

3. **Upload PDFs for processing**:
   - Upload PDF files to the `input/` prefix in the created S3 bucket
   - The Lambda function will automatically process them
   - Split PDFs will appear in the `output/` folder
   - Unsplit PDFs will be moved to the `processed/` folder

## Usage

### 1. Document Upload with Access Control

Upload PDFs using a structured path for automatic access control metadata:

```bash
# Structure: input/[department]/[classification]/[created_by]/filename.pdf
aws s3 cp financial_report.pdf s3://[bucket-name]/input/finance/confidential/john.doe@company.com/q4_report.pdf
aws s3 cp employee_handbook.pdf s3://[bucket-name]/input/hr/internal/jane.smith@company.com/handbook.pdf
aws s3 cp public_brochure.pdf s3://[bucket-name]/input/marketing/public/system/company_brochure.pdf
```

The system will automatically:
1. Extract access control metadata from the file path
2. Analyze the PDF page count using PyPDF2
3. Split documents >20 pages into chunks
4. Store processed documents with metadata for Knowledge Base indexing
5. Index documents in Bedrock Knowledge Base with OpenSearch

### 2. Knowledge Base Queries via Private API

⚠️ **Important**: The API Gateway is **PRIVATE** and only accessible from within the VPC.

Query the knowledge base from resources within the VPC:

```python
# From Lambda function or EC2 instance in the VPC
import boto3
import json
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

def query_private_api(query, user_id, user_groups, use_caching=True):
    # Private API endpoint (only accessible from VPC)
    api_url = "https://[api-id].execute-api.us-east-1.amazonaws.com/prod/query"
    
    payload = {
        "query": query,
        "user_id": user_id,
        "user_groups": user_groups,
        "type": "retrieve_and_generate",
        "use_caching": use_caching  # Enable prompt caching for better performance
    }
    
    # Sign request with AWS credentials
    session = boto3.Session()
    credentials = session.get_credentials()
    
    request = AWSRequest(
        method='POST',
        url=api_url,
        data=json.dumps(payload),
        headers={'Content-Type': 'application/json'}
    )
    
    SigV4Auth(credentials, 'execute-api', 'us-east-1').add_auth(request)
    
    response = requests.post(
        request.url,
        data=request.body,
        headers=dict(request.headers)
    )
    
    return response.json()

# Example with caching enabled (default)
result = query_private_api(
    query="What are the key financial metrics for Q4?",
    user_id="john.doe@company.com",
    user_groups=["finance", "executives"],
    use_caching=True
)

# Check if response used cached prompts
if result.get("cached"):
    print(f"✅ Used cached prompt - saved tokens!")
    print(f"Cache performance: {result.get('cache_performance', {})}")
```

### Prompt Caching Benefits

The system includes **Claude prompt caching** for significant performance and cost improvements:

**🚀 Performance Benefits:**
- **Faster Response Times**: Cached system prompts reduce processing latency
- **Reduced Token Usage**: System prompts are cached and reused across requests
- **Better Throughput**: Handle more concurrent requests efficiently

**💰 Cost Benefits:**
- **Lower API Costs**: Cached prompts reduce billable tokens by up to 90%
- **Efficient Resource Usage**: Less compute time per request
- **Scalable Economics**: Cost per query decreases with usage volume

**🔧 How It Works:**
1. **System Prompt Caching**: RAG instructions are cached for 1 hour (configurable)
2. **User Context Grouping**: Cache keys include user groups for appropriate access
3. **Automatic Management**: Cache expiration and refresh handled automatically
4. **Performance Monitoring**: Detailed metrics on cache hit rates and token savings

### 3. Streamlit Frontend Integration (VPC Deployment Required)

⚠️ **Important**: Your Streamlit app must run within the VPC to access the private API.

Deploy your Streamlit app on EC2 or ECS within the VPC:

```python
import streamlit as st
import boto3
import json
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

class PrivateKnowledgeBaseClient:
    def __init__(self, api_url):
        self.api_url = api_url
        self.session = boto3.Session()
        self.credentials = self.session.get_credentials()
    
    def query_knowledge_base(self, query, user_id, user_groups, query_type="retrieve_and_generate"):
        payload = {
            "query": query,
            "user_id": user_id,
            "user_groups": user_groups,
            "type": query_type
        }
        
        # Create signed AWS request for private API
        request = AWSRequest(
            method='POST',
            url=f"{self.api_url}/query",
            data=json.dumps(payload),
            headers={'Content-Type': 'application/json'}
        )
        
        SigV4Auth(self.credentials, 'execute-api', 'us-east-1').add_auth(request)
        
        response = requests.post(
            request.url,
            data=request.body,
            headers=dict(request.headers)
        )
        
        return response.json()

# Streamlit app (must run within VPC)
def main():
    st.title("🔒 Private Knowledge Base")
    st.caption("Secure VPC-only access to your documents")
    
    # Initialize private API client
    api_client = PrivateKnowledgeBaseClient(
        "https://[api-id].execute-api.us-east-1.amazonaws.com/prod"
    )
    
    # User inputs
    query = st.text_input("Ask a question about your documents:")
    user_id = st.text_input("User ID:", value="user@company.com")
    user_groups = st.multiselect("User Groups:", ["finance", "hr", "legal", "executives"])
    
    if st.button("🔍 Query Knowledge Base") and query:
        with st.spinner("Searching secure knowledge base..."):
            try:
                result = api_client.query_knowledge_base(query, user_id, user_groups)
                
                if "generated_response" in result:
                    st.success("**Response:**")
                    st.write(result["generated_response"])
                    
                    if "citations" in result:
                        with st.expander("📚 View Sources"):
                            for i, citation in enumerate(result["citations"]):
                                st.write(f"**Source {i+1}:**")
                                for ref in citation.get("retrievedReferences", []):
                                    st.text(ref.get("content", "")[:300] + "...")
                else:
                    st.warning("No response generated")
                    
            except Exception as e:
                st.error(f"❌ Error accessing private API: {str(e)}")
                st.info("💡 Ensure your Streamlit app is running within the VPC")

if __name__ == "__main__":
    main()
```

**Deployment Options for Streamlit:**
- **EC2 Instance**: Deploy in private subnet with Session Manager access
- **ECS Fargate**: Run containerized Streamlit in private subnet
- **App Runner**: Use VPC connector for private API access

## Access Control System

### Dual Metadata Filtering Approach

The system uses two complementary metadata filtering mechanisms:

#### 1. **Bedrock Knowledge Base Filtering** (S3 PDFs)
- **Method**: Custom metadata tags applied during PDF processing
- **Structure**: Path-based metadata extraction (`input/dept/classification/user/file.pdf`)
- **Filtering**: Vector search with metadata filters in OpenSearch
- **Granularity**: User, group, classification, department level

#### 2. **Kendra ACL Filtering** (SharePoint)
- **Method**: Native SharePoint ACL scanning by Kendra connector
- **Structure**: Automatic capture of SharePoint permissions during indexing
- **Filtering**: JWT token-based user context with ACL enforcement
- **Granularity**: SharePoint-native permissions (site, list, item level)

### Metadata Structure Examples

**PDF Document Metadata:**
```json
{
  "classification": "confidential",
  "department": "finance", 
  "created_by": "john.doe@company.com",
  "access_groups": "finance",
  "access_users": "john.doe@company.com"
}
```

**SharePoint ACL Data:**
```json
{
  "allowed_users": ["john.doe@company.com", "jane.smith@company.com"],
  "allowed_groups": ["Finance Team", "Executives"],
  "permissions": [{"principal": "Finance Team", "type": "group", "permissions": ["read", "contribute"]}]
}
```

### Query-Time Filtering

The orchestration API automatically applies appropriate filters:

1. **PDF Documents**: Metadata-based OR conditions (user access OR group access OR public classification)
2. **SharePoint Content**: JWT token validation with ACL enforcement
3. **Hybrid Queries**: Combined filtering across both sources with unified results

📖 **Detailed Guide**: See `METADATA_FILTERING_GUIDE.md` for comprehensive examples and troubleshooting.

## Configuration

### Environment Variables

**PDF Splitter Lambda:**
- `S3_BUCKET`: S3 bucket name for document storage

**Orchestration API Lambda:**
- `KNOWLEDGE_BASE_ID`: Bedrock Knowledge Base identifier
- `OPENSEARCH_ENDPOINT`: OpenSearch Serverless collection endpoint

### Terraform Outputs

After deployment, you'll receive:
- `s3_bucket_name`: Main document storage bucket
- `knowledge_base_id`: Bedrock Knowledge Base ID
- `orchestration_api_url`: API Gateway endpoint for queries
- `opensearch_collection_endpoint`: OpenSearch collection endpoint

## Monitoring & Observability

### CloudWatch Monitoring
- Lambda function logs with 30-day retention
- Performance metrics and error rate alarms
- X-Ray tracing for distributed request tracking

### Key Metrics to Monitor
- PDF processing success/failure rates
- Knowledge Base indexing status
- API response times and error rates
- OpenSearch query performance

### Alerts
- SNS notifications for critical errors
- Lambda timeout and memory usage alerts
- Knowledge Base sync failures

## Cost Optimization

### Compute Costs
- PDF Splitter: 5-minute timeout, 1GB memory
- Orchestration API: 30-second timeout, 512MB memory
- Serverless architecture scales to zero when not in use

### Storage Costs
- S3 storage for processed documents
- OpenSearch Serverless vector storage (pay-per-use)
- CloudWatch logs retention (30 days)

### API Costs
- Bedrock Knowledge Base queries (pay-per-request)
- Amazon Titan embeddings (pay-per-token)
- API Gateway requests (pay-per-call)

Very cost-effective for enterprise document processing and RAG workflows.