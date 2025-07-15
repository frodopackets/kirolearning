import json
import boto3
import os
import urllib.parse
from typing import Dict, Any, List
import logging
import io
from PyPDF2 import PdfReader, PdfWriter

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
s3_client = boto3.client('s3')

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Lambda function to process PDF documents from S3 and split them using PyPDF2.
    Triggered when a PDF is uploaded to the 'input/' prefix in the S3 bucket.
    """
    try:
        # Parse S3 event
        for record in event['Records']:
            bucket_name = record['s3']['bucket']['name']
            object_key = urllib.parse.unquote_plus(record['s3']['object']['key'])
            
            logger.info(f"Processing file: {object_key} from bucket: {bucket_name}")
            
            # Download PDF from S3
            pdf_content = download_pdf_from_s3(bucket_name, object_key)
            
            # Get PDF page count using PyPDF2
            page_count = get_pdf_page_count(pdf_content)
            logger.info(f"PDF has {page_count} pages")
            
            # If PDF has more than 20 pages, split it
            if page_count > 20:
                split_pdfs = split_pdf_into_chunks(pdf_content, page_count)
                upload_split_pdfs(bucket_name, object_key, split_pdfs)
                logger.info(f"Successfully split PDF into {len(split_pdfs)} parts")
            else:
                logger.info("PDF has 20 or fewer pages, no splitting needed")
                # Move to processed folder
                move_to_processed(bucket_name, object_key, pdf_content)
        
        return {
            'statusCode': 200,
            'body': json.dumps('PDF processing completed successfully')
        }
        
    except Exception as e:
        logger.error(f"Error processing PDF: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }

def download_pdf_from_s3(bucket_name: str, object_key: str) -> bytes:
    """Download PDF content from S3"""
    try:
        response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
        return response['Body'].read()
    except Exception as e:
        logger.error(f"Error downloading PDF from S3: {str(e)}")
        raise

def get_pdf_page_count(pdf_content: bytes) -> int:
    """
    Get PDF page count using PyPDF2.
    """
    try:
        pdf_stream = io.BytesIO(pdf_content)
        pdf_reader = PdfReader(pdf_stream)
        page_count = len(pdf_reader.pages)
        logger.info(f"PDF contains {page_count} pages")
        return page_count
        
    except Exception as e:
        logger.error(f"Error reading PDF with PyPDF2: {str(e)}")
        raise

def split_pdf_into_chunks(pdf_content: bytes, total_pages: int) -> List[bytes]:
    """
    Split PDF into chunks of 20 pages or less using PyPDF2.
    """
    try:
        split_pdfs = []
        pages_per_chunk = 20
        num_chunks = (total_pages + pages_per_chunk - 1) // pages_per_chunk
        
        # Read the original PDF
        pdf_stream = io.BytesIO(pdf_content)
        pdf_reader = PdfReader(pdf_stream)
        
        for chunk_idx in range(num_chunks):
            start_page = chunk_idx * pages_per_chunk
            end_page = min((chunk_idx + 1) * pages_per_chunk, total_pages)
            
            logger.info(f"Creating chunk {chunk_idx + 1}: pages {start_page + 1}-{end_page}")
            
            # Create a new PDF writer for this chunk
            pdf_writer = PdfWriter()
            
            # Add pages to the chunk
            for page_idx in range(start_page, end_page):
                pdf_writer.add_page(pdf_reader.pages[page_idx])
            
            # Write the chunk to bytes
            chunk_stream = io.BytesIO()
            pdf_writer.write(chunk_stream)
            chunk_pdf = chunk_stream.getvalue()
            split_pdfs.append(chunk_pdf)
            
            # Clean up
            chunk_stream.close()
        
        return split_pdfs
        
    except Exception as e:
        logger.error(f"Error splitting PDF with PyPDF2: {str(e)}")
        raise

def upload_split_pdfs(bucket_name: str, original_key: str, split_pdfs: List[bytes]) -> None:
    """Upload split PDF chunks to S3"""
    try:
        base_name = original_key.replace('input/', '').replace('.pdf', '')
        
        for idx, pdf_chunk in enumerate(split_pdfs):
            output_key = f"output/{base_name}_part_{idx + 1}.pdf"
            
            s3_client.put_object(
                Bucket=bucket_name,
                Key=output_key,
                Body=pdf_chunk,
                ContentType='application/pdf'
            )
            
            logger.info(f"Uploaded chunk to: {output_key}")
            
    except Exception as e:
        logger.error(f"Error uploading split PDFs: {str(e)}")
        raise

def move_to_processed(bucket_name: str, original_key: str, pdf_content: bytes) -> None:
    """Move original PDF to processed folder if no splitting was needed"""
    try:
        processed_key = original_key.replace('input/', 'processed/')
        
        s3_client.put_object(
            Bucket=bucket_name,
            Key=processed_key,
            Body=pdf_content,
            ContentType='application/pdf'
        )
        
        # Delete original
        s3_client.delete_object(Bucket=bucket_name, Key=original_key)
        
        logger.info(f"Moved PDF to: {processed_key}")
        
    except Exception as e:
        logger.error(f"Error moving PDF to processed folder: {str(e)}")
        raise