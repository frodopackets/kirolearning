import json
import boto3
import os
import logging
from typing import Dict, Any, List, Optional
from datetime import datetime

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
bedrock_agent_client = boto3.client('bedrock-agent-runtime', region_name='us-east-1')
bedrock_client = boto3.client('bedrock-runtime', region_name='us-east-1')

# Environment variables
KNOWLEDGE_BASE_ID = os.environ.get('KNOWLEDGE_BASE_ID')
OPENSEARCH_ENDPOINT = os.environ.get('OPENSEARCH_ENDPOINT')

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Orchestration API for Bedrock Knowledge Base with metadata filtering.
    Handles secure document retrieval based on user/group access controls.
    """
    try:
        # Parse the request
        if 'body' in event:
            if isinstance(event['body'], str):
                body = json.loads(event['body'])
            else:
                body = event['body']
        else:
            body = event
        
        # Extract request parameters
        query = body.get('query', '')
        user_id = body.get('user_id', '')
        user_groups = body.get('user_groups', [])
        max_results = body.get('max_results', 10)
        retrieval_type = body.get('type', 'retrieve')  # 'retrieve' or 'retrieve_and_generate'
        
        # Validate required parameters
        if not query:
            return create_error_response(400, "Query parameter is required")
        
        if not user_id and not user_groups:
            return create_error_response(400, "Either user_id or user_groups must be provided")
        
        logger.info(f"Processing query: {query[:100]}... for user: {user_id}, groups: {user_groups}")
        
        # Build metadata filters for access control
        metadata_filters = build_access_control_filters(user_id, user_groups)
        
        if retrieval_type == 'retrieve_and_generate':
            # Retrieve and generate response
            response = retrieve_and_generate(query, metadata_filters, max_results)
        else:
            # Just retrieve relevant documents
            response = retrieve_documents(query, metadata_filters, max_results)
        
        return create_success_response(response)
        
    except Exception as e:
        logger.error(f"Error processing request: {str(e)}")
        return create_error_response(500, f"Internal server error: {str(e)}")

def build_access_control_filters(user_id: str, user_groups: List[str]) -> Dict[str, Any]:
    """
    Build metadata filters to ensure users only access documents they're authorized to see.
    
    Expected metadata structure in documents:
    - access_users: List of user IDs who can access the document
    - access_groups: List of groups who can access the document  
    - classification: Document classification level
    - department: Department that owns the document
    - created_by: User who created/uploaded the document
    """
    
    # Build OR conditions for access control
    or_conditions = []
    
    # User has direct access
    if user_id:
        or_conditions.append({
            "equals": {
                "key": "access_users",
                "value": user_id
            }
        })
        
        # User is the creator
        or_conditions.append({
            "equals": {
                "key": "created_by", 
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
    
    # If no specific access controls, allow public documents
    or_conditions.append({
        "equals": {
            "key": "classification",
            "value": "public"
        }
    })
    
    # Build the complete filter
    metadata_filter = {
        "orAll": or_conditions
    }
    
    logger.info(f"Built metadata filter: {json.dumps(metadata_filter, indent=2)}")
    return metadata_filter

def retrieve_documents(query: str, metadata_filters: Dict[str, Any], max_results: int) -> Dict[str, Any]:
    """
    Retrieve relevant documents from the knowledge base with metadata filtering.
    """
    try:
        retrieval_config = {
            "vectorSearchConfiguration": {
                "numberOfResults": max_results,
                "overrideSearchType": "HYBRID"  # Use both semantic and keyword search
            }
        }
        
        # Add metadata filters if provided
        if metadata_filters:
            retrieval_config["vectorSearchConfiguration"]["filter"] = metadata_filters
        
        response = bedrock_agent_client.retrieve(
            knowledgeBaseId=KNOWLEDGE_BASE_ID,
            retrievalQuery={
                "text": query
            },
            retrievalConfiguration=retrieval_config
        )
        
        # Process and format the results
        results = []
        for result in response.get('retrievalResults', []):
            processed_result = {
                "content": result.get('content', {}).get('text', ''),
                "score": result.get('score', 0),
                "location": result.get('location', {}),
                "metadata": result.get('metadata', {})
            }
            
            # Remove sensitive metadata before returning
            processed_result['metadata'] = sanitize_metadata(processed_result['metadata'])
            results.append(processed_result)
        
        return {
            "type": "retrieve",
            "query": query,
            "results": results,
            "total_results": len(results),
            "timestamp": datetime.utcnow().isoformat()
        }
        
    except Exception as e:
        logger.error(f"Error retrieving documents: {str(e)}")
        raise

def retrieve_and_generate(query: str, metadata_filters: Dict[str, Any], max_results: int) -> Dict[str, Any]:
    """
    Retrieve relevant documents and generate a response using Bedrock.
    """
    try:
        retrieval_config = {
            "vectorSearchConfiguration": {
                "numberOfResults": max_results,
                "overrideSearchType": "HYBRID"
            }
        }
        
        # Add metadata filters if provided
        if metadata_filters:
            retrieval_config["vectorSearchConfiguration"]["filter"] = metadata_filters
        
        generation_config = {
            "modelArn": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0",
            "inferenceConfig": {
                "textInferenceConfig": {
                    "maxTokens": 2000,
                    "temperature": 0.1,
                    "topP": 0.9
                }
            }
        }
        
        response = bedrock_agent_client.retrieve_and_generate(
            input={
                "text": query
            },
            retrieveAndGenerateConfiguration={
                "type": "KNOWLEDGE_BASE",
                "knowledgeBaseConfiguration": {
                    "knowledgeBaseId": KNOWLEDGE_BASE_ID,
                    "modelArn": generation_config["modelArn"],
                    "retrievalConfiguration": retrieval_config,
                    "generationConfiguration": generation_config
                }
            }
        )
        
        # Process the response
        generated_text = response.get('output', {}).get('text', '')
        citations = response.get('citations', [])
        
        # Process citations and remove sensitive metadata
        processed_citations = []
        for citation in citations:
            processed_citation = {
                "generatedResponsePart": citation.get('generatedResponsePart', {}),
                "retrievedReferences": []
            }
            
            for ref in citation.get('retrievedReferences', []):
                processed_ref = {
                    "content": ref.get('content', {}).get('text', ''),
                    "location": ref.get('location', {}),
                    "metadata": sanitize_metadata(ref.get('metadata', {}))
                }
                processed_citation['retrievedReferences'].append(processed_ref)
            
            processed_citations.append(processed_citation)
        
        return {
            "type": "retrieve_and_generate",
            "query": query,
            "generated_response": generated_text,
            "citations": processed_citations,
            "timestamp": datetime.utcnow().isoformat()
        }
        
    except Exception as e:
        logger.error(f"Error in retrieve and generate: {str(e)}")
        raise

def sanitize_metadata(metadata: Dict[str, Any]) -> Dict[str, Any]:
    """
    Remove sensitive metadata fields before returning to client.
    """
    sensitive_fields = [
        'access_users', 
        'access_groups', 
        'internal_id',
        'processing_metadata'
    ]
    
    sanitized = {}
    for key, value in metadata.items():
        if key not in sensitive_fields:
            sanitized[key] = value
    
    return sanitized

def create_success_response(data: Dict[str, Any]) -> Dict[str, Any]:
    """Create a successful API response."""
    return {
        'statusCode': 200,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token',
            'Access-Control-Allow-Methods': 'POST,OPTIONS'
        },
        'body': json.dumps(data)
    }

def create_error_response(status_code: int, message: str) -> Dict[str, Any]:
    """Create an error API response."""
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token',
            'Access-Control-Allow-Methods': 'POST,OPTIONS'
        },
        'body': json.dumps({
            'error': message,
            'timestamp': datetime.utcnow().isoformat()
        })
    }

# Example usage and testing functions
def create_sample_request():
    """
    Sample request format for testing the API.
    """
    return {
        "query": "What are the key findings in the financial reports?",
        "user_id": "john.doe@company.com",
        "user_groups": ["finance", "executives"],
        "max_results": 5,
        "type": "retrieve_and_generate"
    }

def create_metadata_example():
    """
    Example of how documents should be tagged with metadata for access control.
    This would typically be done during the document ingestion process.
    """
    return {
        "access_users": ["john.doe@company.com", "jane.smith@company.com"],
        "access_groups": ["finance", "executives"],
        "classification": "confidential",
        "department": "finance",
        "created_by": "john.doe@company.com",
        "document_type": "financial_report",
        "created_date": "2024-01-15",
        "tags": ["quarterly", "revenue", "expenses"]
    }