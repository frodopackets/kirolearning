import json
import boto3
import os
import logging
from typing import Dict, Any, List, Optional
from datetime import datetime, timedelta
import hashlib
import base64

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
kendra_client = boto3.client('kendra', region_name='us-east-1')
bedrock_agent_client = boto3.client('bedrock-agent', region_name='us-east-1')
s3_client = boto3.client('s3')
secrets_client = boto3.client('secretsmanager')

# Environment variables
KENDRA_INDEX_ID = os.environ.get('KENDRA_INDEX_ID')
KNOWLEDGE_BASE_ID = os.environ.get('KNOWLEDGE_BASE_ID')
S3_BUCKET = os.environ.get('S3_BUCKET')
SHAREPOINT_CREDENTIALS_SECRET_ARN = os.environ.get('SHAREPOINT_CREDENTIALS_SECRET_ARN')
SYNC_PREFIX = os.environ.get('SYNC_PREFIX', 'sharepoint-content')

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda function to sync SharePoint content from Kendra to Bedrock Knowledge Base
    while preserving ACL-based access control through metadata.
    """
    try:
        logger.info("Starting SharePoint to Bedrock Knowledge Base sync")
        
        # Get SharePoint documents from Kendra with ACL information
        sharepoint_documents = fetch_sharepoint_documents_with_acl()
        
        if not sharepoint_documents:
            logger.info("No SharePoint documents found to sync")
            return create_success_response("No documents to sync")
        
        logger.info(f"Found {len(sharepoint_documents)} SharePoint documents to sync")
        
        # Convert SharePoint ACLs to Bedrock metadata format
        processed_documents = []
        for doc in sharepoint_documents:
            processed_doc = convert_sharepoint_to_bedrock_format(doc)
            processed_documents.append(processed_doc)
        
        # Upload documents to S3 with ACL-based metadata
        uploaded_files = upload_documents_to_s3(processed_documents)
        
        # Trigger Bedrock Knowledge Base ingestion
        if uploaded_files:
            ingestion_job = trigger_bedrock_ingestion()
            logger.info(f"Started Bedrock ingestion job: {ingestion_job.get('ingestionJobId')}")
        
        return create_success_response({
            "documents_processed": len(processed_documents),
            "files_uploaded": len(uploaded_files),
            "ingestion_job_id": ingestion_job.get('ingestionJobId') if uploaded_files else None
        })
        
    except Exception as e:
        logger.error(f"Error in SharePoint sync: {str(e)}")
        return create_error_response(str(e))

def fetch_sharepoint_documents_with_acl() -> List[Dict[str, Any]]:
    """
    Fetch SharePoint documents from Kendra with their ACL information.
    Uses multiple approaches to ensure we get complete document data and ACL information.
    """
    try:
        documents = []
        
        # Method 1: Use batch_get_document_status to get all SharePoint documents
        sharepoint_doc_ids = get_sharepoint_document_ids()
        
        if sharepoint_doc_ids:
            # Get full document details with ACL information
            documents.extend(fetch_documents_by_ids(sharepoint_doc_ids))
        
        # Method 2: Fallback to query-based approach with SharePoint-specific filters
        if not documents:
            logger.info("No documents found via document IDs, trying query-based approach")
            documents = fetch_sharepoint_documents_via_query()
        
        # Method 3: Direct data source listing (if available)
        if not documents:
            logger.info("No documents found via query, trying data source listing")
            documents = fetch_sharepoint_documents_via_data_source()
        
        return documents
        
    except Exception as e:
        logger.error(f"Error fetching SharePoint documents: {str(e)}")
        raise

def get_sharepoint_document_ids() -> List[str]:
    """
    Get all SharePoint document IDs from Kendra index.
    """
    try:
        document_ids = []
        next_token = None
        
        while True:
            # List all documents in the index
            list_params = {
                'IndexId': KENDRA_INDEX_ID,
                'MaxResults': 100
            }
            
            if next_token:
                list_params['NextToken'] = next_token
            
            response = kendra_client.list_documents(**list_params)
            
            for doc_info in response.get('DocumentMetadataConfigurationList', []):
                # Filter for SharePoint documents based on URI or data source
                doc_id = doc_info.get('Id', '')
                if doc_id and is_sharepoint_document(doc_info):
                    document_ids.append(doc_id)
            
            next_token = response.get('NextToken')
            if not next_token:
                break
        
        return document_ids
        
    except Exception as e:
        logger.warning(f"Error getting SharePoint document IDs: {str(e)}")
        return []

def is_sharepoint_document(doc_info: Dict[str, Any]) -> bool:
    """
    Determine if a document is from SharePoint based on its metadata.
    """
    # Check various indicators that this is a SharePoint document
    indicators = [
        'sharepoint' in str(doc_info).lower(),
        '/sites/' in str(doc_info).lower(),
        '_layouts/' in str(doc_info).lower(),
        '.sharepoint.com' in str(doc_info).lower()
    ]
    return any(indicators)

def fetch_documents_by_ids(document_ids: List[str]) -> List[Dict[str, Any]]:
    """
    Fetch full document details including ACL information using document IDs.
    """
    try:
        documents = []
        
        # Process documents in batches (Kendra has limits on batch operations)
        batch_size = 10
        for i in range(0, len(document_ids), batch_size):
            batch_ids = document_ids[i:i + batch_size]
            
            # Get document status and metadata
            response = kendra_client.batch_get_document_status(
                IndexId=KENDRA_INDEX_ID,
                DocumentIdList=batch_ids
            )
            
            for doc_status in response.get('DocumentStatusList', []):
                if doc_status.get('Status') == 'INDEXED':
                    # Get full document details with retrieve API
                    doc_details = retrieve_document_with_acl(doc_status.get('DocumentId'))
                    if doc_details:
                        documents.append(doc_details)
        
        return documents
        
    except Exception as e:
        logger.warning(f"Error fetching documents by IDs: {str(e)}")
        return []

def retrieve_document_with_acl(document_id: str) -> Optional[Dict[str, Any]]:
    """
    Retrieve a single document with full ACL information using the retrieve API.
    """
    try:
        # Use retrieve API to get full document content and metadata
        response = kendra_client.retrieve(
            IndexId=KENDRA_INDEX_ID,
            QueryText=f'_document_id:"{document_id}"',
            PageSize=1
        )
        
        for item in response.get('ResultItems', []):
            return extract_document_with_acl(item)
        
        return None
        
    except Exception as e:
        logger.warning(f"Error retrieving document {document_id}: {str(e)}")
        return None

def fetch_sharepoint_documents_via_query() -> List[Dict[str, Any]]:
    """
    Fallback method: Fetch SharePoint documents using targeted queries.
    """
    try:
        documents = []
        
        # Use specific SharePoint-related queries to find documents
        sharepoint_queries = [
            'source:sharepoint',
            'sharepoint_site_url:*',
            'sharepoint_web_url:*',
            '_source_uri:*sharepoint*',
            '_source_uri:*/sites/*'
        ]
        
        for query_text in sharepoint_queries:
            next_token = None
            
            while True:
                query_params = {
                    'IndexId': KENDRA_INDEX_ID,
                    'QueryText': query_text,
                    'PageSize': 100,
                    'QueryResultTypeFilter': 'DOCUMENT',
                    'AttributeFilter': {
                        'EqualsTo': {
                            'Key': '_data_source_id',
                            'Value': {
                                'StringValue': get_sharepoint_data_source_id()
                            }
                        }
                    } if get_sharepoint_data_source_id() else None
                }
                
                if next_token:
                    query_params['PageToken'] = next_token
                
                response = kendra_client.query(**query_params)
                
                for item in response.get('ResultItems', []):
                    doc_info = extract_document_with_acl(item)
                    if doc_info and not any(d['id'] == doc_info['id'] for d in documents):
                        documents.append(doc_info)
                
                next_token = response.get('NextToken')
                if not next_token:
                    break
        
        return documents
        
    except Exception as e:
        logger.warning(f"Error fetching SharePoint documents via query: {str(e)}")
        return []

def get_sharepoint_data_source_id() -> Optional[str]:
    """
    Get the SharePoint data source ID from Kendra index.
    """
    try:
        response = kendra_client.list_data_sources(IndexId=KENDRA_INDEX_ID)
        
        for data_source in response.get('DataSourceSummaryItems', []):
            if 'sharepoint' in data_source.get('Name', '').lower():
                return data_source.get('Id')
        
        return None
        
    except Exception as e:
        logger.warning(f"Error getting SharePoint data source ID: {str(e)}")
        return None

def fetch_sharepoint_documents_via_data_source() -> List[Dict[str, Any]]:
    """
    Last resort: Fetch documents by directly querying the SharePoint data source.
    """
    try:
        documents = []
        sharepoint_ds_id = get_sharepoint_data_source_id()
        
        if not sharepoint_ds_id:
            return documents
        
        # Query documents from specific data source
        response = kendra_client.query(
            IndexId=KENDRA_INDEX_ID,
            QueryText='*',
            AttributeFilter={
                'EqualsTo': {
                    'Key': '_data_source_id',
                    'Value': {
                        'StringValue': sharepoint_ds_id
                    }
                }
            },
            PageSize=100
        )
        
        for item in response.get('ResultItems', []):
            doc_info = extract_document_with_acl(item)
            if doc_info:
                documents.append(doc_info)
        
        return documents
        
    except Exception as e:
        logger.warning(f"Error fetching SharePoint documents via data source: {str(e)}")
        return []

def parse_sharepoint_acl_v2(acl_list: List[str]) -> Dict[str, Any]:
    """
    Parse SharePoint Connector V2 ACL structure with enhanced granularity.
    V2 provides more detailed permission information including permission levels.
    """
    try:
        acl_data = {
            'allowed_users': [],
            'allowed_groups': [],
            'denied_users': [],
            'denied_groups': [],
            'permission_levels': {},  # V2 enhancement: track permission levels
            'inheritance_info': {}    # V2 enhancement: track inheritance
        }
        
        for acl_entry in acl_list:
            try:
                # V2 ACL entries are JSON-formatted strings with enhanced structure
                acl_obj = json.loads(acl_entry) if isinstance(acl_entry, str) else acl_entry
                
                principal = acl_obj.get('principal', '')
                principal_type = acl_obj.get('type', 'user')  # user, group, role
                permissions = acl_obj.get('permissions', [])
                access_type = acl_obj.get('access', 'allow')  # allow, deny
                inheritance = acl_obj.get('inheritance', 'inherited')
                
                # Categorize by access type and principal type
                if access_type.lower() == 'allow':
                    if principal_type.lower() == 'group':
                        acl_data['allowed_groups'].append(principal)
                    else:
                        acl_data['allowed_users'].append(principal)
                elif access_type.lower() == 'deny':
                    if principal_type.lower() == 'group':
                        acl_data['denied_groups'].append(principal)
                    else:
                        acl_data['denied_users'].append(principal)
                
                # V2 enhancement: Store permission levels for fine-grained access control
                acl_data['permission_levels'][principal] = {
                    'permissions': permissions,
                    'type': principal_type,
                    'access': access_type,
                    'inheritance': inheritance
                }
                
            except (json.JSONDecodeError, KeyError) as e:
                logger.warning(f"Failed to parse V2 ACL entry: {acl_entry}, error: {str(e)}")
                continue
        
        # Remove duplicates
        acl_data['allowed_users'] = list(set(acl_data['allowed_users']))
        acl_data['allowed_groups'] = list(set(acl_data['allowed_groups']))
        acl_data['denied_users'] = list(set(acl_data['denied_users']))
        acl_data['denied_groups'] = list(set(acl_data['denied_groups']))
        
        return acl_data
        
    except Exception as e:
        logger.error(f"Error parsing SharePoint V2 ACL: {str(e)}")
        # Return basic structure on error
        return {
            'allowed_users': [],
            'allowed_groups': [],
            'denied_users': [],
            'denied_groups': [],
            'permission_levels': {},
            'inheritance_info': {}
        }

def extract_acl_from_v2_template_metadata(metadata: Dict[str, Any]) -> Dict[str, Any]:
    """
    Extract ACL information from SharePoint Connector V2 template metadata structure.
    V2 template uses different field names than the legacy connector.
    """
    try:
        acl_data = {
            'allowed_users': [],
            'allowed_groups': [],
            'denied_users': [],
            'denied_groups': [],
            'permission_levels': {},
            'inheritance_info': {}
        }
        
        # V2 template-specific ACL field extraction
        # The V2 template may store ACL data in different fields
        
        # Check for V2 template ACL fields (these are the actual field names from V2 template)
        if '_acl_allowed_users' in metadata:
            acl_data['allowed_users'] = metadata['_acl_allowed_users'] if isinstance(metadata['_acl_allowed_users'], list) else [metadata['_acl_allowed_users']]
        
        if '_acl_allowed_groups' in metadata:
            acl_data['allowed_groups'] = metadata['_acl_allowed_groups'] if isinstance(metadata['_acl_allowed_groups'], list) else [metadata['_acl_allowed_groups']]
        
        if '_acl_denied_users' in metadata:
            acl_data['denied_users'] = metadata['_acl_denied_users'] if isinstance(metadata['_acl_denied_users'], list) else [metadata['_acl_denied_users']]
        
        if '_acl_denied_groups' in metadata:
            acl_data['denied_groups'] = metadata['_acl_denied_groups'] if isinstance(metadata['_acl_denied_groups'], list) else [metadata['_acl_denied_groups']]
        
        # V2 template permission level extraction
        if '_acl_permissions' in metadata:
            try:
                permissions_data = json.loads(metadata['_acl_permissions']) if isinstance(metadata['_acl_permissions'], str) else metadata['_acl_permissions']
                if isinstance(permissions_data, dict):
                    acl_data['permission_levels'] = permissions_data
            except (json.JSONDecodeError, TypeError):
                logger.warning(f"Failed to parse V2 template permissions data: {metadata.get('_acl_permissions')}")
        
        # Alternative V2 template field names (fallback)
        if not acl_data['allowed_users'] and not acl_data['allowed_groups']:
            # Try alternative V2 field names
            for field_name, acl_key in [
                ('_allowed_principals', 'allowed_users'),
                ('_allowed_groups', 'allowed_groups'),
                ('_denied_principals', 'denied_users'),
                ('_denied_groups', 'denied_groups')
            ]:
                if field_name in metadata:
                    value = metadata[field_name]
                    if isinstance(value, list):
                        acl_data[acl_key] = value
                    elif isinstance(value, str):
                        acl_data[acl_key] = [value]
        
        # Clean up and deduplicate
        for key in ['allowed_users', 'allowed_groups', 'denied_users', 'denied_groups']:
            if acl_data[key]:
                acl_data[key] = list(set([str(item) for item in acl_data[key] if item]))
        
        return acl_data
        
    except Exception as e:
        logger.error(f"Error extracting ACL from V2 template metadata: {str(e)}")
        return {
            'allowed_users': [],
            'allowed_groups': [],
            'denied_users': [],
            'denied_groups': [],
            'permission_levels': {},
            'inheritance_info': {}
        }

def extract_document_with_acl(kendra_item: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """
    Extract document content and ACL information from Kendra result item.
    """
    try:
        # Get document content
        content = ""
        if kendra_item.get('DocumentExcerpt', {}).get('Text'):
            content = kendra_item['DocumentExcerpt']['Text']
        elif kendra_item.get('DocumentTitle', {}).get('Text'):
            content = kendra_item['DocumentTitle']['Text']
        
        if not content:
            return None
        
        # Extract metadata and ACL information
        metadata = {}
        acl_data = {
            'allowed_users': [],
            'allowed_groups': [],
            'denied_users': [],
            'denied_groups': []
        }
        
        # Process document attributes (V2 template-based structure)
        for attr in kendra_item.get('DocumentAttributes', []):
            key = attr.get('Key', '')
            value = attr.get('Value', {})
            
            # Handle different value types
            if 'StringValue' in value:
                metadata[key] = value['StringValue']
            elif 'StringListValue' in value:
                metadata[key] = value['StringListValue']
                
                # Extract V2 ACL information from template-based attributes
                if key == 'sharepoint_acl_v2':
                    # V2 template ACL structure is more comprehensive
                    acl_data = parse_sharepoint_acl_v2(value['StringListValue'])
                elif key == '_source_uri':
                    # V2 template uses _source_uri for document URI
                    metadata['source_uri'] = value['StringValue']
                elif key == '_category':
                    # V2 template categorizes content types
                    metadata['content_category'] = value['StringValue']
            elif 'LongValue' in value:
                metadata[key] = value['LongValue']
            elif 'DateValue' in value:
                metadata[key] = value['DateValue'].isoformat() if value['DateValue'] else None
        
        # Handle V2 template-specific ACL extraction
        # V2 template stores ACL data in a structured format
        if not acl_data['allowed_users'] and not acl_data['allowed_groups']:
            # Extract ACL from V2 template metadata structure
            acl_data = extract_acl_from_v2_template_metadata(metadata)
        
        return {
            'id': kendra_item.get('Id', ''),
            'content': content,
            'title': kendra_item.get('DocumentTitle', {}).get('Text', ''),
            'uri': kendra_item.get('DocumentURI', ''),
            'metadata': metadata,
            'acl_data': acl_data,
            'score': kendra_item.get('ScoreAttributes', {}).get('ScoreConfidence', 0)
        }
        
    except Exception as e:
        logger.error(f"Error extracting document ACL: {str(e)}")
        return None

def convert_sharepoint_to_bedrock_format_v2(sharepoint_doc: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert SharePoint V2 template document with enhanced ACL to Bedrock metadata format.
    Uses actual V2 template field names from the template configuration.
    """
    acl_data = sharepoint_doc.get('acl_data', {})
    original_metadata = sharepoint_doc.get('metadata', {})
    
    # V2 Template Enhanced metadata with actual field names
    bedrock_metadata = {
        # Source information (V2 template fields)
        'source': 'sharepoint',
        'source_type': 'sharepoint_page',
        'sharepoint_uri': sharepoint_doc.get('uri', ''),
        'sharepoint_site_url': original_metadata.get('sharepoint_site_url', ''),
        'sharepoint_web_url': original_metadata.get('sharepoint_web_url', ''),
        'sharepoint_content_type': original_metadata.get('sharepoint_content_type', ''),
        
        # Content metadata (V2 template actual field names)
        'title': original_metadata.get('sharepoint_title', sharepoint_doc.get('title', '')),
        'author': original_metadata.get('sharepoint_author', ''),
        'created_date': original_metadata.get('sharepoint_created', ''),
        'modified_date': original_metadata.get('sharepoint_modified', ''),
        'created_by': original_metadata.get('sharepoint_author', 'system'),
        
        # Access control metadata (converted from V2 template ACL fields)
        'access_users': '|'.join(acl_data.get('allowed_users', [])),
        'access_groups': '|'.join(acl_data.get('allowed_groups', [])),
        'denied_users': '|'.join(acl_data.get('denied_users', [])),
        'denied_groups': '|'.join(acl_data.get('denied_groups', [])),
        
        # V2 Template Enhancement: Permission level tracking
        'permission_summary': create_permission_summary(acl_data.get('permission_levels', {})),
        'has_full_control_users': has_permission_level(acl_data, 'full_control'),
        'has_contribute_access': has_permission_level(acl_data, 'contribute'),
        'has_read_only_access': has_permission_level(acl_data, 'read'),
        
        # V2 Template Enhanced classification based on permission complexity
        'classification': determine_classification_from_acl_v2(acl_data),
        'department': extract_department_from_groups(acl_data.get('allowed_groups', [])),
        
        # V2 Template Permission inheritance tracking
        'has_inherited_permissions': has_inherited_permissions(acl_data),
        'has_direct_permissions': has_direct_permissions(acl_data),
        
        # Additional V2 template fields
        'sharepoint_site': extract_site_from_uri(sharepoint_doc.get('uri', '')),
        'sharepoint_file_extension': original_metadata.get('sharepoint_file_extension', ''),
    }
    
    return {
        'content': sharepoint_doc.get('content', ''),
        'metadata': bedrock_metadata,
        'filename': generate_filename_from_sharepoint_doc(sharepoint_doc)
    }

def convert_sharepoint_to_bedrock_format(sharepoint_doc: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert SharePoint document with ACL to Bedrock Knowledge Base format with metadata.
    Now uses the V2 template-based conversion for enhanced metadata.
    """
    # Use the V2 template-based conversion for all SharePoint documents
    return convert_sharepoint_to_bedrock_format_v2(sharepoint_doc)

def determine_classification_from_acl(acl_data: Dict[str, Any]) -> str:
    """
    Determine document classification based on SharePoint ACL data.
    """
    allowed_groups = acl_data.get('allowed_groups', [])
    allowed_users = acl_data.get('allowed_users', [])
    
    # If everyone or large groups have access, it's likely public/internal
    public_indicators = ['Everyone', 'All Users', 'Company Users', 'All Employees']
    if any(group in allowed_groups for group in public_indicators):
        return 'internal'
    
    # If only specific small groups, it's likely confidential
    if len(allowed_groups) <= 2 and len(allowed_users) <= 5:
        return 'confidential'
    
    # If moderate access, it's internal
    if len(allowed_groups) <= 5:
        return 'internal'
    
    # Default to internal
    return 'internal'

def extract_department_from_groups(groups: List[str]) -> str:
    """
    Extract department from SharePoint group names.
    """
    department_keywords = {
        'finance': ['finance', 'accounting', 'treasury', 'budget'],
        'hr': ['hr', 'human resources', 'people', 'talent'],
        'legal': ['legal', 'compliance', 'risk', 'audit'],
        'engineering': ['engineering', 'development', 'tech', 'it'],
        'sales': ['sales', 'business development', 'revenue'],
        'marketing': ['marketing', 'communications', 'brand'],
        'operations': ['operations', 'ops', 'facilities']
    }
    
    for group in groups:
        group_lower = group.lower()
        for dept, keywords in department_keywords.items():
            if any(keyword in group_lower for keyword in keywords):
                return dept
    
    return 'general'

def extract_site_from_uri(uri: str) -> str:
    """
    Extract SharePoint site name from URI.
    """
    try:
        if '/sites/' in uri:
            site_part = uri.split('/sites/')[1].split('/')[0]
            return site_part
        return 'unknown'
    except:
        return 'unknown'

def create_permission_summary(permission_levels: Dict[str, Any]) -> str:
    """Create a summary of permission levels for advanced filtering."""
    summary_parts = []
    for principal, details in permission_levels.items():
        permissions = details.get('permissions', [])
        if permissions:
            highest_permission = get_highest_permission(permissions)
            summary_parts.append(f"{principal}:{highest_permission}")
    return '|'.join(summary_parts)

def get_highest_permission(permissions: List[str]) -> str:
    """Determine the highest permission level from a list."""
    permission_hierarchy = ['read', 'contribute', 'design', 'full_control']
    for perm in reversed(permission_hierarchy):
        if perm in [p.lower() for p in permissions]:
            return perm
    return 'read'  # Default to read if no match

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

def determine_classification_from_acl_v2(acl_data: Dict[str, Any]) -> str:
    """Enhanced classification determination using V2 permission data."""
    permission_levels = acl_data.get('permission_levels', {})
    allowed_groups = acl_data.get('allowed_groups', [])
    allowed_users = acl_data.get('allowed_users', [])
    
    # Check for full control permissions (highly sensitive)
    full_control_count = sum(1 for details in permission_levels.values() 
                           if 'full_control' in [p.lower() for p in details.get('permissions', [])])
    
    # Check for public access indicators
    public_indicators = ['Everyone', 'All Users', 'Company Users', 'All Employees', 'Authenticated Users']
    has_public_access = any(group in allowed_groups for group in public_indicators)
    
    # Enhanced classification logic
    if full_control_count <= 2 and len(allowed_users) <= 3:
        return 'restricted'  # Very limited access
    elif full_control_count <= 5 and not has_public_access:
        return 'confidential'  # Limited access, no public groups
    elif has_public_access:
        return 'internal'  # Company-wide access
    elif len(allowed_groups) <= 3:
        return 'confidential'  # Department-level access
    else:
        return 'internal'  # Default to internal

def generate_filename_from_sharepoint_doc(doc: Dict[str, Any]) -> str:
    """
    Generate a filename for the SharePoint document.
    """
    title = doc.get('title', 'sharepoint_document')
    doc_id = doc.get('id', 'unknown')
    
    # Clean title for filename
    clean_title = ''.join(c for c in title if c.isalnum() or c in (' ', '-', '_')).strip()
    clean_title = clean_title.replace(' ', '_')
    
    # Create unique filename
    filename = f"{clean_title}_{doc_id[:8]}.txt"
    return filename

def upload_documents_to_s3(documents: List[Dict[str, Any]]) -> List[str]:
    """
    Upload SharePoint documents to S3 with ACL-based metadata.
    """
    try:
        uploaded_files = []
        
        for doc in documents:
            # Create S3 key with sync prefix
            s3_key = f"{SYNC_PREFIX}/{doc['filename']}"
            
            # Prepare document content with metadata header
            content_with_metadata = create_document_with_metadata_header(doc)
            
            # Upload to S3 with metadata
            s3_client.put_object(
                Bucket=S3_BUCKET,
                Key=s3_key,
                Body=content_with_metadata.encode('utf-8'),
                ContentType='text/plain',
                Metadata={
                    # Convert metadata to S3 metadata format (string values only)
                    key: str(value) for key, value in doc['metadata'].items()
                }
            )
            
            uploaded_files.append(s3_key)
            logger.info(f"Uploaded SharePoint document: {s3_key}")
        
        return uploaded_files
        
    except Exception as e:
        logger.error(f"Error uploading documents to S3: {str(e)}")
        raise

def create_document_with_metadata_header(doc: Dict[str, Any]) -> str:
    """
    Create document content with metadata header for better indexing.
    """
    metadata = doc['metadata']
    content = doc['content']
    
    # Create metadata header
    header_parts = [
        f"Title: {metadata.get('title', '')}",
        f"Source: SharePoint ({metadata.get('sharepoint_site', '')})",
        f"Author: {metadata.get('author', '')}",
        f"Created: {metadata.get('created_date', '')}",
        f"Modified: {metadata.get('modified_date', '')}",
        f"Department: {metadata.get('department', '')}",
        f"Classification: {metadata.get('classification', '')}",
        "---"
    ]
    
    header = "\n".join(header_parts)
    
    return f"{header}\n\n{content}"

def trigger_bedrock_ingestion() -> Dict[str, Any]:
    """
    Trigger Bedrock Knowledge Base ingestion job for new SharePoint content.
    """
    try:
        response = bedrock_agent_client.start_ingestion_job(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            dataSourceId=get_bedrock_data_source_id(),
            description=f"SharePoint sync ingestion - {datetime.utcnow().isoformat()}"
        )
        
        return response.get('ingestionJob', {})
        
    except Exception as e:
        logger.error(f"Error triggering Bedrock ingestion: {str(e)}")
        raise

def get_bedrock_data_source_id() -> str:
    """
    Get the Bedrock Knowledge Base data source ID for S3.
    """
    try:
        response = bedrock_agent_client.list_data_sources(
            knowledgeBaseId=KNOWLEDGE_BASE_ID
        )
        
        # Find S3 data source
        for data_source in response.get('dataSourceSummaries', []):
            if data_source.get('name', '').lower().find('s3') != -1:
                return data_source['dataSourceId']
        
        # If no S3 data source found, return the first one
        if response.get('dataSourceSummaries'):
            return response['dataSourceSummaries'][0]['dataSourceId']
        
        raise Exception("No data source found for Knowledge Base")
        
    except Exception as e:
        logger.error(f"Error getting Bedrock data source ID: {str(e)}")
        raise

def create_success_response(data: Any) -> Dict[str, Any]:
    """Create a successful response."""
    return {
        'statusCode': 200,
        'body': json.dumps({
            'status': 'success',
            'data': data,
            'timestamp': datetime.utcnow().isoformat()
        })
    }

def create_error_response(error_message: str) -> Dict[str, Any]:
    """Create an error response."""
    return {
        'statusCode': 500,
        'body': json.dumps({
            'status': 'error',
            'error': error_message,
            'timestamp': datetime.utcnow().isoformat()
        })
    }