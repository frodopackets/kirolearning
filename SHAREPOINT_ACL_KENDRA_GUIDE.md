# SharePoint ACL Data Retrieval from Kendra - Implementation Guide

## Overview

This guide documents how the SharePoint sync process retrieves Access Control List (ACL) data from Amazon Kendra and processes it for the unified Bedrock Knowledge Base. The implementation uses a multi-layered approach to ensure comprehensive data retrieval and robust ACL processing.

## Architecture Overview

```
SharePoint → Kendra Index → SharePoint Sync Lambda → S3 → Bedrock Knowledge Base
                ↑                    ↑
            ACL Data            ACL Processing
            Storage             & Conversion
```

## Multi-Layered Data Retrieval Strategy

### Method 1: Document ID-Based Retrieval (Primary)

**Purpose**: Get complete document metadata including full ACL information

**Process**:
1. Use `list_documents()` to enumerate all documents in Kendra index
2. Filter documents to identify SharePoint sources using URI patterns:
   - Contains `sharepoint`
   - Contains `/sites/`
   - Contains `_layouts/`
   - Contains `.sharepoint.com`
3. Use `batch_get_document_status()` for efficient batch processing
4. Use `retrieve()` API to get full document content and metadata

**Advantages**:
- Gets complete document metadata
- Most reliable for ACL data
- Efficient batch processing

**Code Reference**:
```python
def get_sharepoint_document_ids() -> List[str]
def fetch_documents_by_ids(document_ids: List[str]) -> List[Dict[str, Any]]
def retrieve_document_with_acl(document_id: str) -> Optional[Dict[str, Any]]
```

### Method 2: Targeted Query-Based Approach (Fallback)

**Purpose**: Use specific queries to find SharePoint documents when Method 1 fails

**Queries Used**:
- `source:sharepoint` - Documents tagged as SharePoint source
- `sharepoint_site_url:*` - Documents with SharePoint site URLs
- `sharepoint_web_url:*` - Documents with SharePoint web URLs
- `_source_uri:*sharepoint*` - Documents with SharePoint in URI
- `_source_uri:*/sites/*` - Documents from SharePoint sites

**Additional Filtering**:
- Uses `_data_source_id` attribute filter to target SharePoint data source
- Deduplicates results across multiple queries
- Processes results in paginated batches

**Code Reference**:
```python
def fetch_sharepoint_documents_via_query() -> List[Dict[str, Any]]
def get_sharepoint_data_source_id() -> Optional[str]
```

### Method 3: Data Source-Specific Querying (Last Resort)

**Purpose**: Direct querying of SharePoint data source when other methods fail

**Process**:
1. Identify SharePoint data source ID
2. Query all documents from that specific data source
3. Extract ACL information from document attributes

**Code Reference**:
```python
def fetch_sharepoint_documents_via_data_source() -> List[Dict[str, Any]]
```

## SharePoint V2 Template ACL Structure

### Primary ACL Fields

The SharePoint Connector V2 template stores ACL data in structured JSON format:

```json
{
  "principal": "user@domain.com",
  "type": "user|group|role",
  "permissions": ["read", "contribute", "design", "full_control"],
  "access": "allow|deny",
  "inheritance": "inherited|direct"
}
```

### V2 Template Metadata Fields

**Core ACL Fields**:
- `sharepoint_acl_v2` - Main ACL data (JSON array)
- `_acl_allowed_users` - List of allowed users
- `_acl_allowed_groups` - List of allowed groups
- `_acl_denied_users` - List of denied users
- `_acl_denied_groups` - List of denied groups
- `_acl_permissions` - Detailed permission structure (JSON)

**Alternative Field Names** (Fallback):
- `_allowed_principals` - Generic allowed principals
- `_denied_principals` - Generic denied principals
- `_source_uri` - Document source URI
- `_category` - Content categorization

**Content Metadata Fields**:
- `sharepoint_title` - Document title
- `sharepoint_author` - Document author
- `sharepoint_created` - Creation date
- `sharepoint_modified` - Modification date
- `sharepoint_site_url` - SharePoint site URL
- `sharepoint_web_url` - SharePoint web URL
- `sharepoint_content_type` - Content type
- `sharepoint_file_extension` - File extension

## ACL Data Processing Pipeline

### 1. Raw ACL Extraction

```python
def extract_document_with_acl(kendra_item: Dict[str, Any]) -> Optional[Dict[str, Any]]
```

**Process**:
- Extracts document attributes from Kendra result item
- Handles different value types (StringValue, StringListValue, LongValue, DateValue)
- Identifies ACL-specific attributes
- Falls back to V2 template metadata extraction if needed

### 2. V2 Template ACL Parsing

```python
def parse_sharepoint_acl_v2(acl_list: List[str]) -> Dict[str, Any]
```

**Features**:
- Parses JSON-structured ACL entries
- Categorizes principals by type (user, group, role)
- Tracks permission levels and inheritance
- Handles access types (allow, deny)
- Deduplicates entries

**Output Structure**:
```python
{
    'allowed_users': List[str],
    'allowed_groups': List[str],
    'denied_users': List[str],
    'denied_groups': List[str],
    'permission_levels': Dict[str, Any],
    'inheritance_info': Dict[str, Any]
}
```

### 3. V2 Template Metadata Extraction

```python
def extract_acl_from_v2_template_metadata(metadata: Dict[str, Any]) -> Dict[str, Any]
```

**Handles**:
- Direct ACL field extraction from V2 template
- Alternative field name mapping
- JSON parsing for complex permission structures
- Data validation and cleanup

## Enhanced Bedrock Metadata Conversion

### V2 Template Conversion

```python
def convert_sharepoint_to_bedrock_format_v2(sharepoint_doc: Dict[str, Any]) -> Dict[str, Any]
```

**Enhanced Metadata Fields**:

**Source Information**:
- `source`, `source_type`, `sharepoint_uri`
- `sharepoint_site_url`, `sharepoint_web_url`
- `sharepoint_content_type`

**Content Metadata**:
- `title`, `author`, `created_date`, `modified_date`
- `created_by` (with fallback to 'system')

**Access Control Metadata**:
- `access_users`, `access_groups` (pipe-separated)
- `denied_users`, `denied_groups` (pipe-separated)

**V2 Template Enhancements**:
- `permission_summary` - Detailed permission breakdown
- `has_full_control_users`, `has_contribute_access`, `has_read_only_access`
- `has_inherited_permissions`, `has_direct_permissions`

**Classification & Organization**:
- `classification` - Enhanced classification logic
- `department` - Extracted from group names
- `sharepoint_site`, `sharepoint_file_extension`

### Permission Analysis Functions

**Permission Level Analysis**:
```python
def create_permission_summary(permission_levels: Dict[str, Any]) -> str
def get_highest_permission(permissions: List[str]) -> str
def has_permission_level(acl_data: Dict[str, Any], target_permission: str) -> bool
```

**Inheritance Tracking**:
```python
def has_inherited_permissions(acl_data: Dict[str, Any]) -> bool
def has_direct_permissions(acl_data: Dict[str, Any]) -> bool
```

**Enhanced Classification**:
```python
def determine_classification_from_acl_v2(acl_data: Dict[str, Any]) -> str
```

**Classification Logic**:
- `restricted` - ≤2 full control users, ≤3 total users
- `confidential` - ≤5 full control users, no public access
- `internal` - Public access indicators or moderate access
- Considers permission complexity and access patterns

## Error Handling & Resilience

### Graceful Degradation

1. **Method Fallbacks**: If primary method fails, automatically tries fallback methods
2. **Field Fallbacks**: If V2 template fields missing, tries alternative field names
3. **JSON Parsing**: Handles malformed JSON with warning logs
4. **Data Validation**: Cleans and validates ACL data before processing

### Logging Strategy

- **Info Level**: Successful operations, document counts
- **Warning Level**: Fallback method usage, parsing failures
- **Error Level**: Critical failures that stop processing

### Example Error Handling

```python
try:
    acl_obj = json.loads(acl_entry) if isinstance(acl_entry, str) else acl_entry
    # Process ACL entry
except (json.JSONDecodeError, KeyError) as e:
    logger.warning(f"Failed to parse V2 ACL entry: {acl_entry}, error: {str(e)}")
    continue  # Skip malformed entry, continue processing
```

## Configuration & Environment

### Required Environment Variables

```bash
KENDRA_INDEX_ID=your-kendra-index-id
KNOWLEDGE_BASE_ID=your-bedrock-kb-id
S3_BUCKET=your-s3-bucket
SHAREPOINT_CREDENTIALS_SECRET_ARN=your-secret-arn
SYNC_PREFIX=sharepoint-content  # Optional, defaults to 'sharepoint-content'
```

### AWS Permissions Required

**Kendra Permissions**:
- `kendra:Query`
- `kendra:Retrieve`
- `kendra:ListDocuments`
- `kendra:BatchGetDocumentStatus`
- `kendra:ListDataSources`

**Bedrock Permissions**:
- `bedrock:StartIngestionJob`
- `bedrock:ListDataSources`

**S3 Permissions**:
- `s3:PutObject`
- `s3:PutObjectMetadata`

## Monitoring & Troubleshooting

### Key Metrics to Monitor

1. **Document Retrieval Success Rate**: Percentage of SharePoint documents successfully retrieved
2. **ACL Parsing Success Rate**: Percentage of documents with successfully parsed ACL data
3. **Method Usage Distribution**: Which retrieval method is most commonly used
4. **Classification Distribution**: How documents are being classified

### Common Issues & Solutions

**Issue**: No documents found
- **Check**: Kendra index has SharePoint data source
- **Check**: SharePoint connector is properly configured
- **Check**: Document IDs are being generated correctly

**Issue**: Missing ACL data
- **Check**: V2 template field names match actual connector output
- **Check**: JSON parsing is handling the ACL structure correctly
- **Check**: Alternative field name fallbacks are working

**Issue**: Incorrect classification
- **Check**: Permission level analysis logic
- **Check**: Group name parsing for department extraction
- **Check**: Public access indicator detection

## Best Practices

### Performance Optimization

1. **Batch Processing**: Use batch operations for document retrieval
2. **Pagination**: Handle large document sets with proper pagination
3. **Caching**: Consider caching SharePoint data source ID
4. **Parallel Processing**: Process document conversion in parallel where possible

### Data Quality

1. **Validation**: Always validate ACL data structure before processing
2. **Deduplication**: Remove duplicate entries in ACL lists
3. **Normalization**: Normalize principal names and permission levels
4. **Fallbacks**: Provide sensible defaults for missing data

### Security Considerations

1. **Credential Management**: Use AWS Secrets Manager for SharePoint credentials
2. **Access Logging**: Log all ACL processing for audit purposes
3. **Data Encryption**: Ensure S3 objects are encrypted at rest
4. **Principle of Least Privilege**: Grant minimal required permissions

## Future Enhancements

### Potential Improvements

1. **Incremental Sync**: Only sync changed documents
2. **Real-time Updates**: Use SharePoint webhooks for real-time ACL updates
3. **Advanced Analytics**: Track permission usage patterns
4. **Custom Classification**: Machine learning-based document classification
5. **ACL Validation**: Validate ACL consistency across SharePoint and Bedrock

### Scalability Considerations

1. **Lambda Concurrency**: Configure appropriate concurrency limits
2. **Batch Size Tuning**: Optimize batch sizes based on document volume
3. **Memory Management**: Monitor Lambda memory usage for large documents
4. **Timeout Handling**: Implement proper timeout and retry logic

---

## Related Documentation

- [SharePoint Connector V2 Guide](SHAREPOINT_CONNECTOR_V2_GUIDE.md)
- [Metadata Filtering Guide](METADATA_FILTERING_GUIDE.md)
- [Unified Architecture Guide](UNIFIED_ARCHITECTURE_GUIDE.md)