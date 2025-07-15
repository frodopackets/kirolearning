# CIS-Compliant PDF Splitter for Bedrock Data Automation

This project deploys a **CIS-compliant** serverless PDF processing solution that prepares documents for downstream Bedrock Data Automation workflows. The system automatically splits PDF documents that exceed 20 pages into smaller chunks suitable for Bedrock Data Automation blueprints.

## Architecture

- **AWS Cloud Control (awscc) Provider**: Uses the latest awscc provider for Terraform
- **Lambda Function**: Python 3.11 runtime with PyPDF2 for efficient PDF processing
- **S3 Buckets**: Separate buckets for documents and access logs with full encryption
- **KMS Encryption**: Customer-managed keys with automatic rotation
- **IAM Role**: Least-privilege permissions following CIS guidelines
- **CloudWatch**: Comprehensive monitoring and alerting
- **Dead Letter Queue**: Error handling and message retention

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

After deployment, you'll get the S3 bucket name in the Terraform output. Upload your PDF files like this:

```bash
aws s3 cp your-document.pdf s3://[bucket-name]/input/your-document.pdf
```

The system will automatically:
1. Analyze the PDF page count
2. Split it if it has more than 20 pages
3. Store results in the appropriate output folder

## Configuration

The Lambda function uses these environment variables:
- `S3_BUCKET`: The S3 bucket name (automatically set by Terraform)

## Monitoring

Check CloudWatch Logs for the Lambda function to monitor processing status and troubleshoot any issues.

## Cost Optimization

- Lambda function has a 5-minute timeout and 1GB memory allocation
- No external API costs - uses only PyPDF2 for processing
- S3 storage costs apply for stored documents
- Very cost-effective solution for high-volume PDF processing