# DEBUG: build timestamp 2025-08-13T09:08 PDT

import json
import boto3
import logging
import os
import urllib.parse
import pandas as pd
import numpy as np
from io import BytesIO
from botocore.exceptions import ClientError
import nltk

nltk.data.path.append("/var/task/nltk_data")
from nltk.tokenize import word_tokenize

logging.basicConfig(level=logging.INFO, format="%(asctime)s - %(levelname)s - %(message)s")
logger = logging.getLogger(__name__)

TOKEN_CHUNK_SIZE = 6000
BATCH_SIZE = 100

def chunk_transcript(transcript: str):
    tokens = word_tokenize(str(transcript))
    return [
        " ".join(tokens[i:i + TOKEN_CHUNK_SIZE])
        for i in range(0, len(tokens), TOKEN_CHUNK_SIZE)
        if " ".join(tokens[i:i + TOKEN_CHUNK_SIZE]).strip()
    ]

def handler(event, context):
    print("***** DEBUG: create_index.py build timestamp 2025-08-13T09:08 PDT *****")
    logger.info(f"Handler invoked with event: {json.dumps(event)}")
    source_bucket = os.environ.get("SOURCE_BUCKET")
    vector_bucket = os.environ.get("VECTOR_BUCKET")
    index_name = os.environ.get("INDEX_NAME")

    print(f"DEBUG ENV: SOURCE_BUCKET={source_bucket} VECTOR_BUCKET={vector_bucket} INDEX_NAME={index_name}")

    if not all([source_bucket, vector_bucket, index_name]):
        logger.error(f"Missing environment variables: SOURCE_BUCKET={source_bucket}, VECTOR_BUCKET={vector_bucket}, INDEX_NAME={index_name}")
        raise ValueError("Missing environment variables")

    s3 = boto3.client("s3", region_name="us-east-1")
    s3vectors_client = boto3.client("s3vectors", region_name="us-east-1")
    bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")

    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        logger.info(f"Processing file: s3://{bucket}/{key}")
        print(f"DEBUG: Processing file s3://{bucket}/{key}")

        try:
            response = s3.get_object(Bucket=bucket, Key=key)
            excel_data = response["Body"].read()
        except Exception as e:
            logger.warning(f"Failed to read S3 object s3://{bucket}/{key}: {str(e)}")
            print(f"DEBUG: Failed to read S3 object: {str(e)}")
            raise

        try:
            df = pd.read_excel(BytesIO(excel_data))
            logger.info(f"Read Excel file with {len(df)} rows and columns: {list(df.columns)}")
            print(f"DEBUG: Excel file read, {len(df)} rows, columns: {list(df.columns)}")
        except Exception as e:
            logger.warning(f"Failed to parse Excel file: {str(e)}")
            print(f"DEBUG: Failed to parse Excel file: {str(e)}")
            raise

        content_column = "Full Video Transcript"
        if content_column not in df.columns:
            logger.warning(f"Expected column '{content_column}' not found in Excel file.")
            print(f"DEBUG: Expected column '{content_column}' not found")
            raise ValueError(f"Missing required column '{content_column}'")

        first_content = None
        for _, row in df.iterrows():
            val = row.get(content_column, "")
            if pd.notna(val) and str(val).strip():
                first_content = str(val)
                break

        if not first_content:
            logger.warning(f"No non-empty '{content_column}' found in file.")
            print(f"DEBUG: No non-empty '{content_column}'")
            raise ValueError(f"No valid transcript text found in '{content_column}'")

        try:
            preview_text = first_content[:1024]
            bedrock_resp = bedrock.invoke_model(
                modelId="amazon.titan-embed-text-v2:0",
                body=json.dumps({"inputText": preview_text})
            )
            first_embedding = json.loads(bedrock_resp["body"].read())["embedding"]
            dimension = len(first_embedding)
            logger.info(f"Determined embedding dimension: {dimension}")
            print(f"DEBUG: Titan embedding dimension: {dimension}")
        except ClientError as e:
            logger.warning(f"Error generating first embedding: {e.response['Error']['Message']}")
            print(f"DEBUG: Error generating embedding: {e.response['Error']['Message']}")
            raise

        # Create index if not exists
        try:
            idx_resp = s3vectors_client.list_indexes(vectorBucketName=vector_bucket)
            existing_indexes = [idx["indexName"] for idx in idx_resp.get("indexes", [])]
            if index_name not in existing_indexes:
                s3vectors_client.create_index(
                    vectorBucketName=vector_bucket,
                    indexName=index_name,
                    dataType="float32",
                    dimension=dimension,
                    distanceMetric="cosine",
                    metadataConfiguration={
                        "nonFilterableMetadataKeys": [
                            "Video Length",
                            "Internal Broadcast Video Link",
                            "External Youtube Link",
                            "Content Link",
                            "source_text",
                            "When Was Each Topic Discussed",
                            "Deck Link",
                            "Video Transcript Summary",
                            "id"
                        ]
                    }
                )
                logger.info(f"Created vector index '{index_name}' in bucket '{vector_bucket}'")
                print(f"DEBUG: Created vector index {index_name}")
            else:
                logger.info(f"Vector index '{index_name}' already exists in '{vector_bucket}'")
                print(f"DEBUG: Vector index already exists: {index_name}")
        except ClientError as e:
            logger.warning(f"Error ensuring index exists: {e.response['Error']['Message']}")
            print(f"DEBUG: Error ensuring index exists: {e.response['Error']['Message']}")
            raise

        vectors = []
        metadata_columns = [col for col in df.columns if col != content_column]

        for row_index, row in df.iterrows():
            content = row.get(content_column, "")
            if pd.isna(content) or not str(content).strip():
                logger.warning(f"Skipping row {row_index} with empty transcript")
                print(f"DEBUG: Skipping row {row_index}, empty transcript")
                continue

            chunks = chunk_transcript(content)
            print(f"DEBUG: Row {row_index} transcript split into {len(chunks)} chunks")
            for chunk_idx, chunk in enumerate(chunks):
                try:
                    resp = bedrock.invoke_model(
                        modelId="amazon.titan-embed-text-v2:0",
                        body=json.dumps({"inputText": chunk})
                    )
                    embedding = json.loads(resp["body"].read())["embedding"]
                    if len(embedding) != dimension:
                        logger.warning(f"Skipping chunk {chunk_idx} of row {row_index} due to dimension mismatch")
                        print(f"DEBUG: Skipping chunk {chunk_idx} dim mismatch")
                        continue

                    embedding = np.array(embedding, dtype=np.float32).tolist()
                    metadata = {col: str(row.get(col, "Not available")) for col in metadata_columns}
                    metadata["id"] = f"row-{row_index}-chunk-{chunk_idx}"
                    metadata["source_text"] = chunk

                    # Final debug print: show vector schema in batch
                    vectors.append({
                        "key": f"row-{row_index}-chunk-{chunk_idx}",
                        "data": {"float32": embedding},
                        "metadata": metadata
                    })
                    print(f"DEBUG: Adding vector key=row-{row_index}-chunk-{chunk_idx}, size={len(embedding)}")

                    if len(vectors) >= BATCH_SIZE:
                        print(f"DEBUG: Uploading batch of {len(vectors)} vectors to index {index_name}")
                        _upload_batch(s3vectors_client, vector_bucket, index_name, vectors)
                        vectors.clear()

                except ClientError as e:
                    logger.warning(f"Failed to embed row {row_index} chunk {chunk_idx}: {e.response['Error']['Message']}")
                    print(f"DEBUG: Embedding failed for row {row_index} chunk {chunk_idx}: {e.response['Error']['Message']}")
                except Exception as e:
                    logger.warning(f"Unexpected error embedding row {row_index} chunk {chunk_idx}: {str(e)}")
                    print(f"DEBUG: Unexpected error for row {row_index} chunk {chunk_idx}: {str(e)}")

        if vectors:
            print(f"DEBUG: Uploading final batch of {len(vectors)} vectors")
            _upload_batch(s3vectors_client, vector_bucket, index_name, vectors)

    print("***** DEBUG: handler complete, exiting *****")
    return {
        "statusCode": 200,
        "body": json.dumps("Successfully processed Excel file")
    }

def _upload_batch(s3vectors_client, vector_bucket, index_name, batch):
    print(f"DEBUG: _upload_batch called with {len(batch)} vectors")
    try:
        resp = s3vectors_client.put_vectors(
            vectorBucketName=vector_bucket,
            indexName=index_name,
            vectors=batch
        )
        logger.info(f"Uploaded batch of {len(batch)} vectors: HTTP {resp.get('ResponseMetadata', {}).get('HTTPStatusCode')}")
        print(f"DEBUG: Batch upload HTTP status {resp.get('ResponseMetadata', {}).get('HTTPStatusCode')}")
    except ClientError as e:
        logger.warning(f"Error uploading batch: {e.response['Error']['Message']}")
        print(f"DEBUG: Error uploading batch: {e.response['Error']['Message']}")
        raise
    except Exception as e:
        logger.warning(f"Unexpected error uploading batch: {str(e)}")
        print(f"DEBUG: Unexpected error uploading batch: {str(e)}")
        raise