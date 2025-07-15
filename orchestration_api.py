import json
import boto3
import os
import logging
import hashlib
from typing import Dict, Any, List, Optional
from datetime import datetime, timedelta

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
bedrock_agent_client = boto3.client('bedrock-agent-runtime', region_name='us-east-1')
bedrock_client = boto3.client('bedrock-runtime', region_name='us-east-1')

# Environment variables
KNOWLEDGE_BASE_ID = os.environ.get('KNOWLEDGE_BASE_ID')
OPENSEARCH_ENDPOINT = os.environ.get('OPENSEARCH_ENDPOINT')

# Prompt caching configuration
CACHE_TTL_MINUTES = int(os.environ.get('CACHE_TTL_MINUTES', '60'))  # 1 hour default
ENABLE_PROMPT_CACHING = os.environ.get('ENABLE_PROMPT_CACHING', 'true').lower() == 'true'

# In-memory cache for prompt caching (in production, use Redis or DynamoDB)
prompt_cache = {}

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
        
        # Check for prompt caching preference
        use_caching = body.get('use_caching', ENABLE_PROMPT_CACHING)
        
        if retrieval_type == 'retrieve_and_generate':
            if use_caching:
                # Use cached prompt approach for better performance
                response = retrieve_and_generate_with_caching(query, metadata_filters, max_results, user_id, user_groups)
            else:
                # Use standard Knowledge Base approach
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

def retrieve_and_generate_with_caching(query: str, metadata_filters: Dict[str, Any], max_results: int, user_id: str, user_groups: List[str]) -> Dict[str, Any]:
    """
    Retrieve relevant documents and generate a response using Claude with prompt caching.
    This approach uses Claude directly with cached system prompts for better performance.
    """
    try:
        # First, retrieve documents using the knowledge base
        documents = retrieve_documents(query, metadata_filters, max_results)
        
        if not documents.get('results'):
            return {
                "type": "retrieve_and_generate_cached",
                "query": query,
                "generated_response": "I couldn't find any relevant documents to answer your question. Please try rephrasing your query or check if you have access to the relevant documents.",
                "citations": [],
                "cached": False,
                "timestamp": datetime.utcnow().isoformat()
            }
        
        # Create context from retrieved documents
        context = create_context_from_documents(documents['results'])
        
        # Generate cache key for the system prompt
        system_prompt = get_system_prompt_for_rag()
        cache_key = generate_cache_key(system_prompt, user_groups)
        
        # Check if we have a cached prompt
        cached_prompt_data = get_cached_prompt(cache_key)
        
        # Generate response using Claude with caching
        response = generate_with_claude_caching(
            query=query,
            context=context,
            system_prompt=system_prompt,
            cache_key=cache_key,
            cached_prompt_data=cached_prompt_data,
            user_id=user_id,
            user_groups=user_groups
        )
        
        # Create citations from the retrieved documents
        citations = create_citations_from_documents(documents['results'], response.get('generated_response', ''))
        
        return {
            "type": "retrieve_and_generate_cached",
            "query": query,
            "generated_response": response.get('generated_response', ''),
            "citations": citations,
            "cached": response.get('cached', False),
            "cache_performance": response.get('cache_performance', {}),
            "timestamp": datetime.utcnow().isoformat()
        }
        
    except Exception as e:
        logger.error(f"Error in cached retrieve and generate: {str(e)}")
        raise

def get_system_prompt_for_rag() -> str:
    """
    Get the system prompt for RAG operations. This will be cached to improve performance.
    """
    return """You are an expert AI assistant helping users find and analyze information from their organization's document repository. Your role is to provide accurate, helpful, and contextually relevant responses based on the provided documents.

## Core Responsibilities:
1. **Document Analysis**: Carefully analyze the provided document excerpts to understand their content, context, and relevance to the user's query.

2. **Accurate Information Extraction**: Extract and synthesize information from the documents to provide comprehensive answers.

3. **Source Attribution**: Always cite your sources and indicate which documents contain the information you're referencing.

4. **Access Control Awareness**: Respect that users can only see documents they have permission to access. Never reference or hint at information from documents not provided in the context.

## Response Guidelines:
- **Be Comprehensive**: Provide thorough answers that address all aspects of the user's question.
- **Be Precise**: Use specific information from the documents rather than general knowledge.
- **Be Transparent**: If information is incomplete or unclear in the provided documents, acknowledge this limitation.
- **Be Professional**: Maintain a professional, helpful tone appropriate for business contexts.

## Citation Format:
When referencing information from documents, use this format:
- For direct quotes: "According to [Document Title/Source], '[exact quote]'"
- For paraphrased content: "Based on [Document Title/Source], [paraphrased information]"
- For multiple sources: "Multiple documents indicate that [information] (Sources: [Doc1], [Doc2])"

## Handling Limitations:
- If no relevant documents are provided, clearly state this and suggest the user refine their query.
- If documents contain conflicting information, present both perspectives and note the discrepancy.
- If a question requires information not present in the documents, acknowledge this limitation.

## Security and Privacy:
- Never make assumptions about document access beyond what's explicitly provided.
- Don't reference or allude to documents or information not included in the current context.
- Maintain confidentiality of sensitive information while providing helpful responses.

You will be provided with relevant document excerpts and a user query. Analyze the documents carefully and provide a comprehensive, well-cited response."""

def generate_cache_key(system_prompt: str, user_groups: List[str]) -> str:
    """
    Generate a cache key for the system prompt based on content and user context.
    """
    # Include user groups in cache key to ensure appropriate access-level caching
    content_to_hash = system_prompt + "|" + "|".join(sorted(user_groups))
    return hashlib.sha256(content_to_hash.encode()).hexdigest()[:16]

def get_cached_prompt(cache_key: str) -> Optional[Dict[str, Any]]:
    """
    Retrieve cached prompt data if available and not expired.
    """
    if cache_key in prompt_cache:
        cached_data = prompt_cache[cache_key]
        cache_time = datetime.fromisoformat(cached_data['timestamp'])
        
        # Check if cache is still valid
        if datetime.utcnow() - cache_time < timedelta(minutes=CACHE_TTL_MINUTES):
            logger.info(f"Cache hit for key: {cache_key}")
            return cached_data
        else:
            # Cache expired, remove it
            del prompt_cache[cache_key]
            logger.info(f"Cache expired for key: {cache_key}")
    
    logger.info(f"Cache miss for key: {cache_key}")
    return None

def store_cached_prompt(cache_key: str, prompt_data: Dict[str, Any]) -> None:
    """
    Store prompt data in cache with timestamp.
    """
    prompt_cache[cache_key] = {
        **prompt_data,
        'timestamp': datetime.utcnow().isoformat()
    }
    logger.info(f"Stored cache for key: {cache_key}")

def generate_with_claude_caching(query: str, context: str, system_prompt: str, cache_key: str, cached_prompt_data: Optional[Dict[str, Any]], user_id: str, user_groups: List[str]) -> Dict[str, Any]:
    """
    Generate response using Claude with prompt caching for improved performance.
    """
    try:
        start_time = datetime.utcnow()
        
        # Prepare the messages for Claude
        messages = [
            {
                "role": "user",
                "content": [
                    {
                        "type": "text",
                        "text": f"""Based on the following document excerpts, please answer the user's question comprehensively and accurately.

## Document Context:
{context}

## User Question:
{query}

## User Context:
- User ID: {user_id}
- User Groups: {', '.join(user_groups)}

Please provide a detailed response with proper citations to the source documents."""
                    }
                ]
            }
        ]
        
        # Prepare the request body with caching
        request_body = {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2000,
            "temperature": 0.1,
            "top_p": 0.9,
            "system": [
                {
                    "type": "text",
                    "text": system_prompt,
                    "cache_control": {"type": "ephemeral"}  # Enable caching for system prompt
                }
            ],
            "messages": messages
        }
        
        # Make the request to Claude
        response = bedrock_client.invoke_model(
            modelId="anthropic.claude-3-sonnet-20240229-v1:0",
            body=json.dumps(request_body)
        )
        
        response_body = json.loads(response['body'].read())
        generated_text = response_body.get('content', [{}])[0].get('text', '')
        
        # Calculate performance metrics
        end_time = datetime.utcnow()
        processing_time = (end_time - start_time).total_seconds()
        
        # Check if this was a cache hit (Claude returns usage info)
        usage = response_body.get('usage', {})
        cache_creation_input_tokens = usage.get('cache_creation_input_tokens', 0)
        cache_read_input_tokens = usage.get('cache_read_input_tokens', 0)
        
        was_cached = cache_read_input_tokens > 0
        
        # Store cache data for future use
        if not cached_prompt_data:
            cache_data = {
                'system_prompt': system_prompt,
                'cache_creation_tokens': cache_creation_input_tokens,
                'user_groups': user_groups
            }
            store_cached_prompt(cache_key, cache_data)
        
        return {
            "generated_response": generated_text,
            "cached": was_cached,
            "cache_performance": {
                "processing_time_seconds": processing_time,
                "cache_creation_tokens": cache_creation_input_tokens,
                "cache_read_tokens": cache_read_input_tokens,
                "total_input_tokens": usage.get('input_tokens', 0),
                "total_output_tokens": usage.get('output_tokens', 0)
            }
        }
        
    except Exception as e:
        logger.error(f"Error generating with Claude caching: {str(e)}")
        raise

def create_context_from_documents(documents: List[Dict[str, Any]]) -> str:
    """
    Create a formatted context string from retrieved documents.
    """
    context_parts = []
    
    for i, doc in enumerate(documents, 1):
        content = doc.get('content', '')
        metadata = doc.get('metadata', {})
        location = doc.get('location', {})
        
        # Extract document identifier
        doc_title = metadata.get('title', location.get('s3Location', {}).get('uri', f'Document {i}'))
        
        context_part = f"""
## Document {i}: {doc_title}
**Relevance Score**: {doc.get('score', 0):.3f}
**Content**: {content}
**Metadata**: {json.dumps(metadata, indent=2)}
"""
        context_parts.append(context_part)
    
    return "\n".join(context_parts)

def create_citations_from_documents(documents: List[Dict[str, Any]], generated_response: str) -> List[Dict[str, Any]]:
    """
    Create citation objects from the retrieved documents.
    """
    citations = []
    
    for doc in documents:
        citation = {
            "generatedResponsePart": {
                "textResponsePart": {
                    "text": generated_response,
                    "span": {
                        "start": 0,
                        "end": len(generated_response)
                    }
                }
            },
            "retrievedReferences": [
                {
                    "content": doc.get('content', ''),
                    "location": doc.get('location', {}),
                    "metadata": sanitize_metadata(doc.get('metadata', {}))
                }
            ]
        }
        citations.append(citation)
    
    return citations

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