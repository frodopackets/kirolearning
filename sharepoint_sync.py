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
    """
    try:
        documents = []
        next_token = None
        
        while True:
            # Query Kendra to get all SharePoint documents
            query_params = {
                'IndexId': KENDRA_INDEX_ID,
                'QueryText': '*',  # Get all documents
                'PageSize': 100,
                'QueryResultTypeFilter': 'DOCUMENT'
            }
            
            if next_token:
                query_params['PageToken'] = next_token
            
            response = kendra_client.query(**query_params)
            
            for item in response.get('ResultItems', []):
                # Extract document with ACL information
                doc_info = extract_document_with_acl(item)
                if doc_info:
                    documents.append(doc_info)
            
            next_token = response.get('NextToken')
            if not next_token:
                break
        
        return documents
        
    except Exception as e:
        logger.error(f"Error fetching SharePoint documents: {str(e)}")
        raise

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
        
        # Process document attributes (V2 enhanced structure)
        for attr in kendra_item.get('DocumentAttributes', []):
            key = attr.get('Key', '')
            value = attr.get('Value', {})
            
            # Handle different value types
            if 'StringValue' in value:
                metadata[key] = value['StringValue']
            elif 'StringListValue' in value:
                metadata[key] = value['StringListValue']
                
                # Extract V2 ACL information from enhanced attributes
                if key == 'sharepoint_acl_v2':
                    # V2 ACL structure is more comprehensive
                    acl_data = parse_sharepoint_acl_v2(value['StringListValue'])
                elif key == 'sharepoint_allowed_users':
                    acl_data['allowed_users'] = value['StringListValue']
                elif key == 'sharepoint_allowed_groups':
                    acl_data['allowed_groups'] = value['StringListValue']
                elif key == 'sharepoint_denied_users':
                    acl_data['denied_users'] = value['StringListValue']
                elif key == 'sharepoint_denied_groups':
                    acl_data['denied_groups'] = value['StringListValue']
            elif 'LongValue' in value:
                metadata[key] = value['LongValue']
            elif 'DateValue' in value:
                metadata[key] = value['DateValue'].isoformat() if value['DateValue'] else None
        
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

def convert_sharepoint_to_bedrock_format(sharepoint_doc: Dict[str, Any]) -> Dict[str, Any]:
    """
    Convert SharePoint document with ACL to Bedrock Knowledge Base format with metadata.
    """
    try:
        acl_data = sharepoint_doc.get('acl_data', {})
        original_metadata = sharepoint_doc.get('metadata', {})
        
        # Convert SharePoint ACL to Bedrock metadata format
        bedrock_metadata = {
            # Source information
            'source': 'sharepoint',
            'source_type': 'sharepoint_page',
            'sharepoint_uri': sharepoint_doc.get('uri', ''),
            'sharepoint_id': sharepoint_doc.get('id', ''),
            
            # Content metadata
            'title': sharepoint_doc.get('title', ''),
            'content_type': original_metadata.get('ContentType', 'SharePoint Page'),
            'created_date': original_metadata.get('Created', datetime.utcnow().strftime('%Y-%m-%d')),
            'modified_date': original_metadata.get('Modified', datetime.utcnow().strftime('%Y-%m-%d')),
            'author': original_metadata.get('Author', ''),
            
            # Access control metadata (converted from SharePoint ACL)
            'access_users': '|'.join(acl_data.get('allowed_users', [])),
            'access_groups': '|'.join(acl_data.get('allowed_groups', [])),
            'denied_users': '|'.join(acl_data.get('denied_users', [])),
            'denied_groups': '|'.join(acl_data.get('denied_groups', [])),
            
            # Classification based on SharePoint site/permissions
            'classification': determine_classification_from_acl(acl_data),
            'department': extract_department_from_groups(acl_data.get('allowed_groups', [])),
            
            # Additional SharePoint metadata
            'sharepoint_site': extract_site_from_uri(sharepoint_doc.get('uri', '')),
            'sharepoint_list': original_metadata.get('List', ''),
            'sharepoint_library': original_metadata.get('Library', '')
        }
        
        return {
            'content': sharepoint_doc.get('content', ''),
            'metadata': bedrock_metadata,
            'filename': generate_filename_from_sharepoint_doc(sharepoint_doc)
        }
        
    except Exception as e:
        logger.error(f"Error converting SharePoint document: {str(e)}")
        raise

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