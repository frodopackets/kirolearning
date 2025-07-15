# Unified Bedrock Knowledge Base Architecture Guide

This guide explains the new unified architecture where SharePoint content is synced into Bedrock Knowledge Base alongside PDF documents, providing a single, consistent RAG experience with ACL-based access control through metadata filtering.

## 🏗️ Architecture Overview

### Previous Architecture (Hybrid Search)
```
┌─────────────────┐    ┌─────────────────┐
│   PDF Documents │    │ SharePoint Pages│
│   (S3 + Bedrock)│    │ (Kendra + ACL)  │
└─────────────────┘    └─────────────────┘
         │                       │
         └───────┬───────────────┘
                 │
         ┌───────▼───────┐
         │ Orchestration │
         │     API       │
         │ (Dual Search) │
         └───────────────┘
```

### New Architecture (Unified Knowledge Base)
```
┌─────────────────┐    ┌─────────────────┐
│   PDF Documents │    │ SharePoint Pages│
│      (S3)       │    │    (Kendra)     │
└─────────┬───────┘    └─────────┬───────┘
          │                      │
          │            ┌─────────▼───────┐
          │            │ SharePoint Sync │
          │            │    Lambda       │
          │            │ (ACL→Metadata)  │
          │            └─────────┬───────┘
          │                      │
          └──────┬─────────────────┘
                 │
         ┌───────▼───────┐
         │    Unified    │
         │ Bedrock KB    │
         │ (All Content) │
         └───────┬───────┘
                 │
         ┌───────▼───────┐
         │ Orchestration │
         │     API       │
         │ (Single KB)   │
         └───────────────┘
```

## 🔄 How SharePoint ACL Sync Works

### Step 1: Kendra Captures SharePoint ACLs

Kendra's SharePoint connector automatically scans and captures ACL information:

```json
{
  "document_id": "sharepoint_page_123",
  "title": "Q4 Financial Review",
  "content": "This quarter we achieved...",
  "sharepoint_acl": {
    "allowed_users": [
      "john.doe@company.com",
      "jane.smith@company.com"
    ],
    "allowed_groups": [
      "Finance Team",
      "Executives"
    ],
    "site_permissions": {
      "site": "https://company.sharepoint.com/sites/finance",
      "list": "Site Pages",
      "item_permissions": "inherited"
    }
  }
}
```

### Step 2: SharePoint Sync Lambda Converts ACLs to Metadata

The sync Lambda queries Kendra and converts SharePoint ACLs to Bedrock metadata format:

```python
def convert_sharepoint_to_bedrock_format(sharepoint_doc):
    """
    Convert SharePoint ACL data to Bedrock Knowledge Base metadata format.
    """
    acl_data = sharepoint_doc.get('acl_data', {})
    
    # Convert SharePoint ACL to Bedrock metadata
    bedrock_metadata = {
        # Source identification
        'source': 'sharepoint',
        'source_type': 'sharepoint_page',
        'sharepoint_uri': sharepoint_doc.get('uri', ''),
        
        # Content metadata
        'title': sharepoint_doc.get('title', ''),
        'author': original_metadata.get('Author', ''),
        'created_date': original_metadata.get('Created', ''),
        'modified_date': original_metadata.get('Modified', ''),
        
        # Access control metadata (converted from SharePoint ACL)
        'access_users': '|'.join(acl_data.get('allowed_users', [])),
        'access_groups': '|'.join(acl_data.get('allowed_groups', [])),
        'denied_users': '|'.join(acl_data.get('denied_users', [])),
        'denied_groups': '|'.join(acl_data.get('denied_groups', [])),
        
        # Derived classification
        'classification': determine_classification_from_acl(acl_data),
        'department': extract_department_from_groups(acl_data.get('allowed_groups', [])),
        
        # SharePoint-specific metadata
        'sharepoint_site': extract_site_from_uri(sharepoint_doc.get('uri', '')),
        'sharepoint_list': original_metadata.get('List', ''),
    }
    
    return bedrock_metadata
```

### Step 3: Upload to S3 with Metadata

SharePoint content is uploaded to S3 with the converted metadata:

```python
def upload_documents_to_s3(documents):
    """
    Upload SharePoint documents to S3 with ACL-based metadata.
    """
    for doc in documents:
        s3_key = f"sharepoint-content/{doc['filename']}"
        
        # Create document with metadata header for better indexing
        content_with_metadata = f"""Title: {doc['metadata']['title']}
Source: SharePoint ({doc['metadata']['sharepoint_site']})
Author: {doc['metadata']['author']}
Department: {doc['metadata']['department']}
Classification: {doc['metadata']['classification']}
---

{doc['content']}"""
        
        # Upload with S3 metadata
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=s3_key,
            Body=content_with_metadata.encode('utf-8'),
            ContentType='text/plain',
            Metadata={
                key: str(value) for key, value in doc['metadata'].items()
            }
        )
```

### Step 4: Bedrock Knowledge Base Ingestion

After uploading to S3, Bedrock Knowledge Base ingests the content:

```python
def trigger_bedrock_ingestion():
    """
    Trigger Bedrock Knowledge Base ingestion for new SharePoint content.
    """
    response = bedrock_agent_client.start_ingestion_job(
        knowledgeBaseId=KNOWLEDGE_BASE_ID,
        dataSourceId=get_s3_data_source_id(),
        description=f"SharePoint sync ingestion - {datetime.utcnow().isoformat()}"
    )
    
    return response.get('ingestionJob', {})
```

## 🔍 Unified Metadata Filtering

### Metadata Structure in Bedrock Knowledge Base

Both PDF and SharePoint documents now use the same metadata structure:

```json
{
  "AMAZON_BEDROCK_TEXT_CHUNK": "Document content here...",
  "AMAZON_BEDROCK_METADATA": {
    // Common fields for both PDFs and SharePoint
    "source": "sharepoint",  // or "pdf"
    "source_type": "sharepoint_page",  // or "pdf_document"
    "classification": "confidential",
    "department": "finance",
    "access_users": "john.doe@company.com|jane.smith@company.com",
    "access_groups": "Finance Team|Executives",
    "created_by": "john.doe@company.com",
    "created_date": "2024-01-15",
    
    // Source-specific fields
    "title": "Q4 Financial Review",
    "author": "john.doe@company.com",
    
    // SharePoint-specific (when source=sharepoint)
    "sharepoint_uri": "https://company.sharepoint.com/sites/finance/...",
    "sharepoint_site": "finance",
    "sharepoint_list": "Site Pages",
    
    // PDF-specific (when source=pdf)
    "s3_location": "s3://bucket/processed/finance_report.pdf",
    "document_type": "financial_report"
  }
}
```

### Query-Time Filtering

The orchestration API applies the same metadata filters to both PDF and SharePoint content:

```python
def build_access_control_filters(user_id: str, user_groups: List[str]):
    """
    Build unified metadata filters for both PDF and SharePoint content.
    """
    or_conditions = []
    
    # User has direct access (works for both PDFs and SharePoint)
    if user_id:
        or_conditions.append({
            "equals": {"key": "access_users", "value": user_id}
        })
        or_conditions.append({
            "equals": {"key": "created_by", "value": user_id}
        })
    
    # User's groups have access (works for both sources)
    for group in user_groups:
        or_conditions.append({
            "equals": {"key": "access_groups", "value": group}
        })
    
    # Public documents (both PDFs and SharePoint)
    or_conditions.append({
        "equals": {"key": "classification", "value": "public"}
    })
    
    return {"orAll": or_conditions}
```

## 🚀 Benefits of Unified Architecture

### 1. **Consistent User Experience**
- Single API endpoint for all content
- Unified search results ranking
- Consistent metadata filtering approach
- Same prompt caching benefits for all content

### 2. **Simplified Architecture**
- One knowledge base to manage
- Single vector search index
- Unified monitoring and alerting
- Reduced complexity in orchestration API

### 3. **Enhanced Performance**
- Single vector search (faster than dual search)
- Consistent prompt caching across all content
- Optimized embedding and indexing
- Better relevance scoring across sources

### 4. **Preserved Security**
- SharePoint ACLs converted to metadata filters
- Same access control granularity maintained
- User/group-based filtering preserved
- Audit trail maintained through metadata

## 📊 Example Query Flow

### User Query: "What are the Q4 financial results?"

**Step 1: Build Metadata Filter**
```python
# User: john.doe@company.com, Groups: ["Finance Team", "Executives"]
metadata_filter = {
    "orAll": [
        {"equals": {"key": "access_users", "value": "john.doe@company.com"}},
        {"equals": {"key": "created_by", "value": "john.doe@company.com"}},
        {"equals": {"key": "access_groups", "value": "Finance Team"}},
        {"equals": {"key": "access_groups", "value": "Executives"}},
        {"equals": {"key": "classification", "value": "public"}}
    ]
}
```

**Step 2: Query Unified Knowledge Base**
```python
response = bedrock_agent_client.retrieve(
    knowledgeBaseId=KNOWLEDGE_BASE_ID,
    retrievalQuery={"text": "What are the Q4 financial results?"},
    retrievalConfiguration={
        "vectorSearchConfiguration": {
            "numberOfResults": 10,
            "overrideSearchType": "HYBRID",
            "filter": metadata_filter
        }
    }
)
```

**Step 3: Results Include Both Sources**
```json
{
  "retrievalResults": [
    {
      "content": {"text": "Q4 revenue increased by 15%..."},
      "score": 0.95,
      "metadata": {
        "source": "pdf",
        "title": "Q4 Financial Report",
        "department": "finance",
        "classification": "confidential"
      }
    },
    {
      "content": {"text": "Our Q4 performance exceeded expectations..."},
      "score": 0.89,
      "metadata": {
        "source": "sharepoint",
        "title": "Q4 Executive Summary",
        "sharepoint_site": "finance",
        "department": "finance"
      }
    }
  ]
}
```

## 🔧 Sync Process Management

### Automated Sync Schedule

SharePoint content is synced daily via EventBridge:

```hcl
resource "aws_cloudwatch_event_rule" "sharepoint_sync_schedule" {
  name                = "sharepoint-sync-schedule"
  description         = "Trigger SharePoint sync to Bedrock Knowledge Base"
  schedule_expression = "cron(0 2 * * ? *)"  # Daily at 2 AM UTC
}
```

### Monitoring and Alerting

```hcl
resource "aws_cloudwatch_metric_alarm" "sharepoint_sync_errors" {
  alarm_name          = "sharepoint-sync-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = "300"
  statistic           = "Sum"
  threshold           = "0"
  alarm_description   = "Monitor SharePoint sync failures"
}
```

### Manual Sync Trigger

```bash
# Trigger manual sync
aws lambda invoke \
  --function-name sharepoint-sync-[suffix] \
  --payload '{}' \
  response.json
```

## 🔍 Troubleshooting

### Common Issues

1. **SharePoint Content Not Appearing in Results**
   - Check sync Lambda logs for errors
   - Verify Kendra connector is syncing SharePoint ACLs
   - Confirm Bedrock ingestion job completed successfully

2. **Access Control Not Working for SharePoint Content**
   - Verify ACL conversion logic in sync Lambda
   - Check metadata structure in S3 objects
   - Confirm user groups match SharePoint group names

3. **Sync Performance Issues**
   - Monitor Lambda execution time and memory usage
   - Check Kendra query pagination and rate limits
   - Optimize S3 upload batch sizes

### Debugging Commands

```bash
# Check sync Lambda logs
aws logs filter-log-events \
  --log-group-name "/aws/lambda/sharepoint-sync-[suffix]" \
  --start-time $(date -d '1 hour ago' +%s)000

# Check Bedrock ingestion status
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id [kb-id] \
  --data-source-id [ds-id] \
  --ingestion-job-id [job-id]

# Verify S3 metadata
aws s3api head-object \
  --bucket [bucket-name] \
  --key sharepoint-content/sample-document.txt
```

This unified architecture provides the best of both worlds: comprehensive content coverage with consistent, secure access control through a single, optimized knowledge base!