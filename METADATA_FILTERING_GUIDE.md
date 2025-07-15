# Unified Metadata Filtering Guide - Bedrock Knowledge Base

This guide explains how metadata filtering works in your unified RAG pipeline where both PDF documents and SharePoint content are stored in a single Bedrock Knowledge Base, providing consistent, secure, user-specific document access through unified metadata filtering.

## 🔍 Overview: Unified Metadata Filtering Architecture

### **Unified Bedrock Knowledge Base Approach**
- **Sources**: PDF documents (S3) + SharePoint content (synced from Kendra)
- **Mechanism**: Consistent metadata schema for all content types
- **Filtering**: Single vector search with unified metadata filters in OpenSearch
- **Access Control**: Consistent application-level filtering for all sources

### **Key Innovation: SharePoint ACL → Metadata Conversion**
- **SharePoint ACLs** are captured by Kendra connector
- **Sync Lambda** converts ACLs to Bedrock metadata format
- **Same filtering logic** applies to both PDFs and SharePoint content
- **Preserved security** with simplified architecture

## 📄 Bedrock Knowledge Base Metadata Filtering (S3 PDFs)

### How PDF Metadata is Applied

When PDFs are uploaded to S3, the Lambda function automatically extracts and applies metadata:

```python
# From lambda_function.py - metadata extraction
def extract_access_metadata(object_key: str) -> Dict[str, str]:
    """
    Extract access control metadata from S3 object key path.
    
    Expected naming convention:
    input/[department]/[classification]/[created_by]/filename.pdf
    
    Examples:
    - input/finance/confidential/john.doe@company.com/quarterly_report.pdf
    - input/hr/internal/jane.smith@company.com/employee_handbook.pdf
    - input/public/public/system/company_brochure.pdf
    """
    
    # Parse path structure
    path_parts = object_key.replace('input/', '').replace('.pdf', '').split('/')
    
    metadata = {
        'classification': 'internal',      # public, internal, confidential, restricted
        'department': 'general',           # finance, hr, legal, engineering, etc.
        'created_by': 'system',           # user who uploaded the document
        'document_type': 'document',       # report, contract, policy, manual
        'created_date': datetime.utcnow().strftime('%Y-%m-%d'),
        'access_groups': 'general',        # groups that can access this document
        'access_users': 'system'          # specific users with access
    }
    
    # Extract from structured path
    if len(path_parts) >= 3:
        metadata['department'] = path_parts[0]      # finance
        metadata['classification'] = path_parts[1]   # confidential
        metadata['created_by'] = path_parts[2]      # john.doe@company.com
        metadata['access_groups'] = path_parts[0]   # finance team access
        metadata['access_users'] = path_parts[2]    # creator access
    
    return metadata
```

### Metadata Structure in OpenSearch

When documents are indexed in Bedrock Knowledge Base, they're stored in OpenSearch with this metadata structure:

```json
{
  "_index": "bedrock-knowledge-base-index",
  "_id": "doc_12345",
  "_source": {
    "AMAZON_BEDROCK_TEXT_CHUNK": "This is the document content...",
    "AMAZON_BEDROCK_METADATA": {
      "classification": "confidential",
      "department": "finance", 
      "created_by": "john.doe@company.com",
      "document_type": "financial_report",
      "created_date": "2024-01-15",
      "access_groups": "finance",
      "access_users": "john.doe@company.com",
      "s3_location": "s3://bucket/processed/finance_confidential_john.doe_quarterly_report.pdf"
    },
    "bedrock-knowledge-base-default-vector": [0.1, 0.2, 0.3, ...]
  }
}
```

### Query-Time Filtering

When users query the system, metadata filters are applied:

```python
# From orchestration_api.py - building access control filters
def build_access_control_filters(user_id: str, user_groups: List[str]) -> Dict[str, Any]:
    """
    Build metadata filters for Bedrock Knowledge Base queries.
    """
    or_conditions = []
    
    # User has direct access (created the document)
    if user_id:
        or_conditions.append({
            "equals": {
                "key": "created_by",
                "value": user_id
            }
        })
        
        # User is explicitly granted access
        or_conditions.append({
            "equals": {
                "key": "access_users",
                "value": user_id
            }
        })
    
    # User's groups have access
    for group in user_groups:
        or_conditions.append({
            "equals": {
                "key": "access_groups",
                "value": group
            }
        })
    
    # Public documents (no restrictions)
    or_conditions.append({
        "equals": {
            "key": "classification",
            "value": "public"
        }
    })
    
    # Build complete OR filter
    return {"orAll": or_conditions}

def build_enhanced_access_control_filters_v2(user_id: str, user_groups: List[str], 
                                            permission_level: str = None) -> Dict[str, Any]:
    """
    Build enhanced metadata filters using SharePoint Connector V2 capabilities.
    Supports permission-level filtering and inheritance-based access control.
    """
    or_conditions = []
    
    # Standard access conditions (backward compatible)
    if user_id:
        or_conditions.extend([
            {"equals": {"key": "created_by", "value": user_id}},
            {"equals": {"key": "access_users", "value": user_id}}
        ])
    
    for group in user_groups:
        or_conditions.append({
            "equals": {"key": "access_groups", "value": group}
        })
    
    or_conditions.append({
        "equals": {"key": "classification", "value": "public"}
    })
    
    # V2 Enhanced filtering conditions
    if permission_level:
        # Filter by specific permission level (read, contribute, full_control)
        or_conditions.append({
            "equals": {"key": f"has_{permission_level}_access", "value": "true"}
        })
    
    # V2 Permission-based filtering
    and_conditions = []
    
    # Add permission summary filtering for more granular control
    if user_id or user_groups:
        permission_conditions = []
        
        if user_id:
            permission_conditions.append({
                "stringContains": {"key": "permission_summary", "value": user_id}
            })
        
        for group in user_groups:
            permission_conditions.append({
                "stringContains": {"key": "permission_summary", "value": group}
            })
        
        if permission_conditions:
            and_conditions.append({"orAll": permission_conditions})
    
    # Combine OR and AND conditions for comprehensive filtering
    if and_conditions:
        return {
            "andAll": [
                {"orAll": or_conditions},
                *and_conditions
            ]
        }
    else:
        return {"orAll": or_conditions}

# Example filter for user john.doe@company.com in groups ["finance", "executives"]
{
  "orAll": [
    {"equals": {"key": "created_by", "value": "john.doe@company.com"}},
    {"equals": {"key": "access_users", "value": "john.doe@company.com"}},
    {"equals": {"key": "access_groups", "value": "finance"}},
    {"equals": {"key": "access_groups", "value": "executives"}},
    {"equals": {"key": "classification", "value": "public"}}
  ]
}
```

### Bedrock Knowledge Base Query with Filters

```python
# Actual query sent to Bedrock Knowledge Base
response = bedrock_agent_client.retrieve(
    knowledgeBaseId=KNOWLEDGE_BASE_ID,
    retrievalQuery={
        "text": "What are the Q4 financial results?"
    },
    retrievalConfiguration={
        "vectorSearchConfiguration": {
            "numberOfResults": 10,
            "overrideSearchType": "HYBRID",  # Vector + keyword search
            "filter": {
                "orAll": [
                    {"equals": {"key": "created_by", "value": "john.doe@company.com"}},
                    {"equals": {"key": "access_groups", "value": "finance"}},
                    {"equals": {"key": "classification", "value": "public"}}
                ]
            }
        }
    }
)
```

## 🔗 SharePoint ACL-to-Metadata Conversion

### How SharePoint ACLs are Captured and Converted

The SharePoint sync process captures ACLs from Kendra and converts them to Bedrock metadata:

**Step 1: Kendra Captures SharePoint ACLs**
```json
{
  "document_id": "sharepoint_page_456",
  "title": "Q4 Financial Review",
  "content": "This quarter we achieved...",
  "sharepoint_metadata": {
    "site_url": "https://company.sharepoint.com/sites/finance",
    "page_url": "https://company.sharepoint.com/sites/finance/SitePages/Q4-Review.aspx",
    "author": "john.doe@company.com",
    "created": "2024-01-15T10:30:00Z",
    "modified": "2024-01-20T14:45:00Z",
    "content_type": "Site Page"
  },
  "acl_data": {
    "allowed_users": [
      "john.doe@company.com",
      "jane.smith@company.com",
      "finance.manager@company.com"
    ],
    "allowed_groups": [
      "Finance Team",
      "Executives", 
      "Finance Managers"
    ],
    "denied_users": [],
    "denied_groups": [],
    "inheritance": "inherited"
  }
}
```

**Step 2: Sync Lambda Converts V2 ACLs to Bedrock Metadata**
```python
def convert_sharepoint_to_bedrock_format_v2(sharepoint_doc):
    """
    Convert SharePoint Connector V2 ACL data to Bedrock Knowledge Base metadata format.
    V2 provides enhanced permission granularity and inheritance information.
    """
    acl_data = sharepoint_doc.get('acl_data', {})
    original_metadata = sharepoint_doc.get('metadata', {})
    
    # V2 Enhanced metadata with permission levels
    bedrock_metadata = {
        # Source identification (V2 enhanced)
        'source': 'sharepoint',
        'source_type': 'sharepoint_page',
        'sharepoint_uri': sharepoint_doc.get('uri', ''),
        'sharepoint_site': extract_site_from_uri(sharepoint_doc.get('uri', '')),
        'sharepoint_site_url': original_metadata.get('sharepoint_site_url', ''),
        'sharepoint_content_type': original_metadata.get('sharepoint_content_type', ''),
        
        # Content metadata (V2 enhanced with millisecond precision)
        'title': sharepoint_doc.get('title', ''),
        'author': original_metadata.get('sharepoint_author', ''),
        'created_date': original_metadata.get('sharepoint_created', ''),
        'modified_date': original_metadata.get('sharepoint_modified', ''),
        
        # Basic access control metadata (backward compatible)
        'access_users': '|'.join(acl_data.get('allowed_users', [])),
        'access_groups': '|'.join(acl_data.get('allowed_groups', [])),
        'denied_users': '|'.join(acl_data.get('denied_users', [])),
        'denied_groups': '|'.join(acl_data.get('denied_groups', [])),
        
        # V2 Enhanced permission-based metadata for advanced filtering
        'permission_summary': create_permission_summary(acl_data.get('permission_levels', {})),
        'has_full_control_users': has_permission_level(acl_data, 'full_control'),
        'has_contribute_access': has_permission_level(acl_data, 'contribute'),
        'has_read_only_access': has_permission_level(acl_data, 'read'),
        
        # V2 Enhanced classification based on permission complexity
        'classification': determine_classification_from_acl_v2(acl_data),
        'department': extract_department_from_groups(acl_data.get('allowed_groups', [])),
        'created_by': original_metadata.get('sharepoint_author', 'system'),
        
        # V2 Permission inheritance tracking
        'has_inherited_permissions': has_inherited_permissions(acl_data),
        'has_direct_permissions': has_direct_permissions(acl_data)
    }
    
    return bedrock_metadata

# V2 Helper functions for enhanced filtering capabilities
def create_permission_summary(permission_levels: Dict[str, Any]) -> str:
    """Create a summary of permission levels for advanced filtering."""
    summary_parts = []
    for principal, details in permission_levels.items():
        permissions = details.get('permissions', [])
        if permissions:
            highest_permission = get_highest_permission(permissions)
            summary_parts.append(f"{principal}:{highest_permission}")
    return '|'.join(summary_parts)

def has_permission_level(acl_data: Dict[str, Any], target_permission: str) -> bool:
    """Check if any principal has the specified permission level."""
    permission_levels = acl_data.get('permission_levels', {})
    for details in permission_levels.values():
        permissions = [p.lower() for p in details.get('permissions', [])]
        if target_permission.lower() in permissions:
            return True
    return False

def has_inherited_permissions(acl_data: Dict[str, Any]) -> bool:
    """Check if document has inherited permissions."""
    permission_levels = acl_data.get('permission_levels', {})
    return any(details.get('inheritance') == 'inherited' 
              for details in permission_levels.values())

def has_direct_permissions(acl_data: Dict[str, Any]) -> bool:
    """Check if document has direct (non-inherited) permissions."""
    permission_levels = acl_data.get('permission_levels', {})
    return any(details.get('inheritance') == 'direct' 
              for details in permission_levels.values())
```

**Step 3: SharePoint Content Uploaded to S3 with Converted Metadata**
```python
def upload_documents_to_s3(documents):
    """
    Upload SharePoint documents to S3 with ACL-based metadata for Bedrock ingestion.
    """
    for doc in documents:
        s3_key = f"sharepoint-content/{doc['filename']}"
        
        # Create document with metadata header for better indexing
        content_with_metadata = f"""Title: {doc['metadata']['title']}
Source: SharePoint ({doc['metadata']['sharepoint_site']})
Author: {doc['metadata']['author']}
Department: {doc['metadata']['department']}
Classification: {doc['metadata']['classification']}
Access Groups: {doc['metadata']['access_groups']}
---

{doc['content']}"""
        
        # Upload with S3 metadata (converted from SharePoint ACL)
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=s3_key,
            Body=content_with_metadata.encode('utf-8'),
            ContentType='text/plain',
            Metadata={
                # Same metadata structure as PDFs
                'source': 'sharepoint',
                'classification': doc['metadata']['classification'],
                'department': doc['metadata']['department'],
                'access_users': doc['metadata']['access_users'],
                'access_groups': doc['metadata']['access_groups'],
                'created_by': doc['metadata']['created_by'],
                'sharepoint_uri': doc['metadata']['sharepoint_uri']
            }
        )
```

**Step 4: Bedrock Knowledge Base Ingestion**
After uploading, Bedrock Knowledge Base ingests SharePoint content with metadata converted from V2 template fields:

```json
{
  "_index": "bedrock-knowledge-base-index",
  "_id": "sharepoint_doc_789",
  "_source": {
    "AMAZON_BEDROCK_TEXT_CHUNK": "Q4 Financial Review content...",
    "AMAZON_BEDROCK_METADATA": {
      "source": "sharepoint",
      "source_type": "sharepoint_page",
      "classification": "confidential",
      "department": "finance",
      
      // Converted from V2 template ACL fields
      "access_users": "john.doe@company.com|jane.smith@company.com",
      "access_groups": "Finance Team|Executives",
      "denied_users": "",
      "denied_groups": "",
      
      // V2 template metadata fields
      "sharepoint_author": "john.doe@company.com",
      "sharepoint_created": "2024-01-15T10:30:00.123Z",
      "sharepoint_modified": "2024-01-20T14:45:30.456Z",
      "sharepoint_title": "Q4 Financial Review",
      "sharepoint_content_type": "Site Page",
      "sharepoint_site_url": "https://company.sharepoint.com/sites/finance",
      "sharepoint_web_url": "https://company.sharepoint.com/sites/finance/SitePages",
      
      // Derived fields
      "title": "Q4 Financial Review",
      "author": "john.doe@company.com",
      "created_by": "john.doe@company.com",
      "sharepoint_uri": "https://company.sharepoint.com/sites/finance/SitePages/Q4-Review.aspx",
      "sharepoint_site": "finance"
    },
    "bedrock-knowledge-base-default-vector": [0.4, 0.5, 0.6, ...]
  }
}
```

### V2 Template Field Mapping

The SharePoint Connector V2 template produces these specific field names:

| V2 Template Field | Converted Bedrock Metadata | Purpose |
|-------------------|----------------------------|---------|
| `sharepoint_author` | `author`, `created_by` | Document author |
| `sharepoint_created` | `created_date` | Creation timestamp (millisecond precision) |
| `sharepoint_modified` | `modified_date` | Modification timestamp |
| `sharepoint_title` | `title` | Document title |
| `sharepoint_content_type` | `content_type` | SharePoint content type |
| `sharepoint_site_url` | `sharepoint_site_url` | Full site URL |
| `sharepoint_web_url` | `sharepoint_web_url` | Web URL |
| `_acl_allowed_users` | `access_users` | Allowed users (pipe-separated) |
| `_acl_allowed_groups` | `access_groups` | Allowed groups (pipe-separated) |
| `_acl_denied_users` | `denied_users` | Denied users |
| `_acl_denied_groups` | `denied_groups` | Denied groups |
| `_acl_permissions` | `permission_levels` | V2 enhanced permission data |

## 🔄 Unified Filtering: Single Knowledge Base Query

### Unified Query Processing Flow

With the new architecture, all content (PDFs + SharePoint) is queried from a single Bedrock Knowledge Base:

```python
def retrieve_documents_unified(query: str, metadata_filters: Dict, max_results: int, 
                              user_id: str, user_groups: List[str]):
    """
    Retrieve documents from unified Bedrock Knowledge Base containing both PDFs and SharePoint content.
    """
    # Single query to Bedrock Knowledge Base (contains both PDFs and SharePoint content)
    response = bedrock_agent_client.retrieve(
        knowledgeBaseId=KNOWLEDGE_BASE_ID,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {
                "numberOfResults": max_results,
                "overrideSearchType": "HYBRID",  # Vector + keyword search
                "filter": metadata_filters  # Same filters for both PDFs and SharePoint
            }
        }
    )
    
    # Process results - both PDFs and SharePoint content use same structure
    results = []
    for result in response.get('retrievalResults', []):
        metadata = result.get('metadata', {})
        
        processed_result = {
            "content": result.get('content', {}).get('text', ''),
            "score": result.get('score', 0),
            "location": result.get('location', {}),
            "metadata": metadata,
            "source": metadata.get('source', 'unknown'),  # 'pdf' or 'sharepoint'
            "source_type": metadata.get('source_type', 'unknown'),
            "access_method": "unified_metadata_filtering"
        }
        
        results.append(processed_result)
    
    return results
```

## 🛡️ Unified Security Model

### Unified Bedrock Knowledge Base (All Content)
| Aspect | Implementation |
|--------|----------------|
| **Access Control** | Unified metadata filtering for all content types |
| **Granularity** | User, group, classification, department (consistent across sources) |
| **Performance** | Single fast vector search with metadata filters |
| **Flexibility** | Consistent metadata schema for PDFs and SharePoint |
| **Maintenance** | Automated for PDFs (path-based) and SharePoint (ACL conversion) |
| **Security Model** | Preserved SharePoint ACLs via metadata conversion |

### Security Benefits of Unified Approach
- **Consistent Access Control**: Same filtering logic for all content types
- **Preserved SharePoint Security**: ACLs converted to metadata without losing granularity
- **Simplified Architecture**: Single knowledge base reduces complexity and attack surface
- **Enhanced Performance**: One vector search instead of multiple system queries
- **Unified Audit Trail**: All access logged through single Bedrock Knowledge Base

## 📊 Practical Examples

### Example 1: Finance User Query (Unified Architecture)

```python
# User: john.doe@company.com, Groups: ["Finance Team", "Executives"]
query = "What are the Q4 revenue projections?"

# Single Unified Filter (applied to ALL content in Bedrock Knowledge Base):
unified_filter = {
    "orAll": [
        {"equals": {"key": "created_by", "value": "john.doe@company.com"}},
        {"equals": {"key": "access_users", "value": "john.doe@company.com"}},
        {"equals": {"key": "access_groups", "value": "Finance Team"}},
        {"equals": {"key": "access_groups", "value": "Executives"}},
        {"equals": {"key": "classification", "value": "public"}}
    ]
}

# Single Query to Unified Bedrock Knowledge Base:
response = bedrock_agent_client.retrieve(
    knowledgeBaseId=KNOWLEDGE_BASE_ID,
    retrievalQuery={"text": query},
    retrievalConfiguration={
        "vectorSearchConfiguration": {
            "numberOfResults": 10,
            "overrideSearchType": "HYBRID",
            "filter": unified_filter  # Same filter for both PDFs and SharePoint content
        }
    }
)

# Unified Results (both PDFs and SharePoint content):
# - PDF: "Q4_Financial_Projections.pdf" (source: pdf, created_by: john.doe@company.com)
# - PDF: "Executive_Summary_Q4.pdf" (source: pdf, access_groups: Executives)
# - SharePoint: "Q4 Revenue Analysis" (source: sharepoint, access_groups: Finance Team)
# - SharePoint: "Executive Dashboard" (source: sharepoint, access_groups: Executives)
```

### Example 2: HR User Query (Unified Architecture)

```python
# User: hr.manager@company.com, Groups: ["HR Team", "Managers"]
query = "Show me the employee onboarding procedures"

# Single Unified Filter:
unified_filter = {
    "orAll": [
        {"equals": {"key": "created_by", "value": "hr.manager@company.com"}},
        {"equals": {"key": "access_users", "value": "hr.manager@company.com"}},
        {"equals": {"key": "access_groups", "value": "HR Team"}},
        {"equals": {"key": "access_groups", "value": "Managers"}},
        {"equals": {"key": "classification", "value": "public"}}
    ]
}

# Unified Results from Single Knowledge Base:
# - PDF: "Employee_Handbook.pdf" (source: pdf, access_groups: HR Team)
# - PDF: "Onboarding_Checklist.pdf" (source: pdf, department: hr)
# - SharePoint: "New Employee Onboarding" (source: sharepoint, access_groups: HR Team)
# - SharePoint: "Manager's Guide to Onboarding" (source: sharepoint, access_groups: Managers)
# - SharePoint: "HR Policies and Procedures" (source: sharepoint, access_groups: HR Team)
```

### Example 3: Cross-Department Query (Unified Architecture)

```python
# User: project.manager@company.com, Groups: ["Project Managers", "Engineering"]
query = "Find all project documentation and technical specifications"

# Single Unified Filter:
unified_filter = {
    "orAll": [
        {"equals": {"key": "created_by", "value": "project.manager@company.com"}},
        {"equals": {"key": "access_users", "value": "project.manager@company.com"}},
        {"equals": {"key": "access_groups", "value": "Project Managers"}},
        {"equals": {"key": "access_groups", "value": "Engineering"}},
        {"equals": {"key": "classification", "value": "public"}}
    ]
}

# Unified Results from Single Knowledge Base (both PDFs and SharePoint):
# - PDF: "Project_Charter_Alpha.pdf" (source: pdf, access_groups: Project Managers)
# - PDF: "Technical_Specifications.pdf" (source: pdf, department: engineering)
# - SharePoint: "Project Alpha Status" (source: sharepoint, access_groups: Project Managers)
# - SharePoint: "Engineering Standards" (source: sharepoint, access_groups: Engineering)
# - SharePoint: "Cross-functional Project Updates" (source: sharepoint, access_groups: Project Managers|Engineering)

# All results ranked by relevance in single vector search!
```

## 🔧 Troubleshooting Metadata Filtering

### Common Issues and Solutions

1. **No Results from Bedrock Knowledge Base**
   ```bash
   # Check document metadata in OpenSearch
   curl -X GET "https://opensearch-endpoint/_search" \
     -H "Content-Type: application/json" \
     -d '{"query": {"match_all": {}}, "size": 1}'
   
   # Verify metadata structure matches filter expectations
   ```

2. **SharePoint Content Not Accessible**
   ```bash
   # Check SharePoint sync Lambda logs
   aws logs filter-log-events \
     --log-group-name "/aws/lambda/sharepoint-sync-[suffix]" \
     --start-time $(date -d '1 hour ago' +%s)000
   
   # Check Bedrock ingestion status
   aws bedrock-agent get-ingestion-job \
     --knowledge-base-id [kb-id] \
     --data-source-id [ds-id] \
     --ingestion-job-id [job-id]
   
   # Verify S3 metadata for SharePoint content
   aws s3api head-object \
     --bucket [bucket-name] \
     --key sharepoint-content/sample-document.txt
   ```

3. **Inconsistent Access Control**
   ```python
   # Debug metadata filters
   logger.info(f"Applied filter: {json.dumps(metadata_filter, indent=2)}")
   logger.info(f"User context: {user_id}, Groups: {user_groups}")
   ```

## 📈 Performance Optimization

### Unified Bedrock Knowledge Base
- **Metadata Filtering**: Use specific filters to reduce search scope across all content types
- **Indexing Strategy**: Optimize metadata fields for common query patterns
- **Prompt Caching**: Cache system prompts for consistent performance across all sources
- **Batch Processing**: Sync SharePoint content in batches to minimize ingestion time

### SharePoint Sync Optimization
- **Incremental Sync**: Only sync changed SharePoint content to reduce processing time
- **ACL Complexity**: Monitor and optimize complex SharePoint permission structures
- **Sync Scheduling**: Schedule syncs during low-usage periods (default: 2 AM UTC)
- **Error Handling**: Implement retry logic for failed ACL conversions

### Query Performance
- **Single Vector Search**: Unified knowledge base provides faster search than dual queries
- **Consistent Ranking**: All content ranked together for better relevance
- **Reduced Latency**: Eliminate cross-system query coordination overhead
- **Unified Caching**: Prompt caching benefits apply to all content types

This unified filtering approach provides comprehensive, secure access control while delivering superior performance and user experience across both PDF documents and SharePoint content!