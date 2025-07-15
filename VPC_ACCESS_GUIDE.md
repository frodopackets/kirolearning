# VPC-Only API Gateway Access Guide

This guide explains how to access the private API Gateway that's only available within the VPC.

## Architecture Overview

The API Gateway is configured as **PRIVATE** with these security controls:
- ✅ **VPC-Only Access**: Only accessible from within the VPC
- ✅ **VPC Endpoint**: Uses Interface VPC endpoint for API Gateway
- ✅ **IAM Authorization**: Still requires AWS IAM credentials
- ✅ **Resource Policy**: Restricts access to specific VPC endpoint

## Access Methods

### 1. From EC2 Instance in the VPC

Deploy an EC2 instance in one of the private subnets:

```bash
# Create an EC2 instance in the private subnet
aws ec2 run-instances \
  --image-id ami-0c55b159cbfafe1f0 \
  --instance-type t3.micro \
  --subnet-id subnet-xxxxxxxxx \
  --security-group-ids sg-xxxxxxxxx \
  --iam-instance-profile Name=YourInstanceProfile

# SSH into the instance (via bastion host or Session Manager)
# Then make API calls from within the VPC
curl -X POST https://[api-id].execute-api.us-east-1.amazonaws.com/prod/query \
  -H "Content-Type: application/json" \
  -H "Authorization: AWS4-HMAC-SHA256 ..." \
  -d '{
    "query": "What are the key findings?",
    "user_id": "user@company.com",
    "user_groups": ["finance"],
    "type": "retrieve_and_generate"
  }'
```

### 2. From Lambda Function in the VPC

Create a Lambda function in the same VPC to call the API:

```python
import boto3
import json
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

def lambda_handler(event, context):
    # API Gateway endpoint (private)
    api_url = "https://[api-id].execute-api.us-east-1.amazonaws.com/prod/query"
    
    # Prepare the request
    payload = {
        "query": event.get("query", ""),
        "user_id": event.get("user_id", ""),
        "user_groups": event.get("user_groups", []),
        "type": "retrieve_and_generate"
    }
    
    # Create AWS request with IAM signing
    session = boto3.Session()
    credentials = session.get_credentials()
    
    request = AWSRequest(
        method='POST',
        url=api_url,
        data=json.dumps(payload),
        headers={'Content-Type': 'application/json'}
    )
    
    # Sign the request
    SigV4Auth(credentials, 'execute-api', 'us-east-1').add_auth(request)
    
    # Make the request
    response = requests.post(
        request.url,
        data=request.body,
        headers=dict(request.headers)
    )
    
    return {
        'statusCode': 200,
        'body': response.json()
    }
```

### 3. From Streamlit App in the VPC

Deploy your Streamlit app on an EC2 instance or ECS container within the VPC:

```python
import streamlit as st
import boto3
import json
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

class PrivateAPIClient:
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
        
        # Create and sign AWS request
        request = AWSRequest(
            method='POST',
            url=f"{self.api_url}/query",
            data=json.dumps(payload),
            headers={'Content-Type': 'application/json'}
        )
        
        SigV4Auth(self.credentials, 'execute-api', 'us-east-1').add_auth(request)
        
        # Make the request
        response = requests.post(
            request.url,
            data=request.body,
            headers=dict(request.headers)
        )
        
        return response.json()

# Streamlit app
def main():
    st.title("Private Knowledge Base Query")
    
    # Initialize API client
    api_client = PrivateAPIClient("https://[api-id].execute-api.us-east-1.amazonaws.com/prod")
    
    # User inputs
    query = st.text_input("Enter your question:")
    user_id = st.text_input("User ID:", value="user@company.com")
    user_groups = st.multiselect("User Groups:", ["finance", "hr", "legal", "executives"])
    
    if st.button("Query Knowledge Base") and query:
        with st.spinner("Searching knowledge base..."):
            try:
                result = api_client.query_knowledge_base(query, user_id, user_groups)
                
                if "generated_response" in result:
                    st.success("Response:")
                    st.write(result["generated_response"])
                    
                    if "citations" in result:
                        st.subheader("Sources:")
                        for citation in result["citations"]:
                            for ref in citation.get("retrievedReferences", []):
                                st.text(ref.get("content", "")[:200] + "...")
                else:
                    st.error("No response generated")
                    
            except Exception as e:
                st.error(f"Error: {str(e)}")

if __name__ == "__main__":
    main()
```

### 4. VPC Peering for External Access

If you need to access from another VPC or on-premises:

```hcl
# VPC Peering Connection
resource "aws_vpc_peering_connection" "main" {
  peer_vpc_id = var.peer_vpc_id
  vpc_id      = var.main_vpc_id
  auto_accept = true

  tags = {
    Name = "rag-pipeline-peering"
  }
}

# Route table entries for peering
resource "aws_route" "peer_route" {
  route_table_id            = var.peer_route_table_id
  destination_cidr_block    = var.main_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.main.id
}
```

## Security Considerations

### Network Security
- API Gateway only accepts connections from the VPC endpoint
- Lambda functions run in private subnets with no direct internet access
- All traffic stays within AWS backbone network

### IAM Security
- API calls still require valid AWS IAM credentials
- Resource-based policies control access at the API level
- User/group-based metadata filtering at the application level

### Monitoring
- VPC Flow Logs capture all network traffic
- CloudTrail logs all API Gateway calls
- CloudWatch monitors Lambda performance and errors

## Troubleshooting

### Common Issues

1. **Connection Timeout**
   - Ensure you're calling from within the VPC
   - Check security group rules allow HTTPS (443) outbound
   - Verify VPC endpoint is healthy

2. **403 Forbidden**
   - Check IAM permissions for execute-api:Invoke
   - Verify the API Gateway resource policy
   - Ensure you're using the correct VPC endpoint

3. **DNS Resolution Issues**
   - Ensure VPC has DNS resolution enabled
   - Check that private DNS is enabled on VPC endpoint
   - Use VPC endpoint DNS names if needed

### Testing Connectivity

```bash
# Test VPC endpoint connectivity
nslookup [api-id].execute-api.us-east-1.amazonaws.com

# Test API Gateway health
curl -v https://[api-id].execute-api.us-east-1.amazonaws.com/prod/query \
  -H "Content-Type: application/json" \
  -d '{"query":"test"}'
```

## Cost Implications

- **VPC Endpoints**: ~$7.20/month per endpoint + data processing charges
- **NAT Gateways**: ~$32.40/month per AZ + data processing charges
- **No Internet Gateway charges** for API traffic (stays within AWS)

The private architecture provides enhanced security at a modest cost increase for VPC networking components.