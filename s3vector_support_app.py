import boto3
import logging
import json
import os
import time
import cfnresponse
from botocore.exceptions import ClientError

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def handler(event, context):
    logger.info(f"Handler invoked with event: {json.dumps(event)}")
    status = cfnresponse.SUCCESS
    reason = ''
    physical_resource_id = event.get('PhysicalResourceId')
    try:
        request_type = event.get('RequestType')
        if not request_type:
            logger.error('Missing RequestType in event')
            status = cfnresponse.FAILED
            reason = 'Missing RequestType'
            return
        properties = event.get('ResourceProperties', {})
        bucket_name = properties.get('BucketName')
        logger.info(f'Properties - BucketName: {bucket_name}')

        if not bucket_name:
            logger.error(f'Missing BucketName: {bucket_name}')
            status = cfnresponse.FAILED
            reason = 'Missing BucketName'
            return

        remaining_time = context.get_remaining_time_in_millis()
        logger.info(f'Remaining time: {remaining_time}ms')
        if remaining_time < 10000:
            logger.error(f'Insufficient time remaining: {remaining_time}ms')
            status = cfnresponse.FAILED
            reason = 'Insufficient time'
            return

        physical_resource_id = physical_resource_id or f'vector-bucket-{bucket_name}'

        # Use region from environment, fallback to us-east-1
        region = os.environ.get('AWS_REGION', 'us-east-1')
        s3vectors_client = boto3.client('s3vectors', region_name=region)

        max_retries = 3

        for attempt in range(max_retries):
            try:
                if request_type == 'Create':
                    logger.info(f'Creating vector bucket {bucket_name}')
                    s3vectors_client.create_vector_bucket(vectorBucketName=bucket_name)
                    reason = f'Created bucket {bucket_name}'
                elif request_type == 'Update':
                    logger.info(f'Updating vector bucket {bucket_name} (no-op)')
                    reason = 'Updated (no-op)'
                elif request_type == 'Delete':
                    logger.info(f'Attempting to delete vector bucket {bucket_name}')
                    try:
                        s3vectors_client.delete_vector_bucket(vectorBucketName=bucket_name)
                        reason = f'Deleted bucket {bucket_name}'
                        logger.info(reason)
                    except ClientError as e:
                        error_code = e.response.get('Error', {}).get('Code')
                        if error_code in ['ResourceNotFoundException', 'BucketNotFound']:
                            reason = f'Bucket {bucket_name} not found, no deletion needed'
                            logger.info(reason)
                        elif error_code in ['ThrottlingException', 'TooManyRequestsException'] and attempt < max_retries - 1:
                            logger.warning(f'Throttling error on attempt {attempt+1}: {str(e)}, retrying...')
                            time.sleep(2 ** attempt)
                            continue
                        else:
                            logger.error(f'Error deleting bucket: {str(e)}')
                            status = cfnresponse.FAILED
                            reason = f'Failed to delete bucket: {str(e)[:200]}'
                    except Exception as e:
                        logger.error(f'Unexpected error during delete: {str(e)}')
                        status = cfnresponse.FAILED
                        reason = f'Unexpected error: {str(e)[:200]}'
                        break
                break  # Success, exit retry loop
            except Exception as e:
                if attempt < max_retries - 1:
                    logger.warning(f'Error on attempt {attempt+1}: {str(e)}, retrying...')
                    time.sleep(2 ** attempt)
                    continue
                status = cfnresponse.FAILED
                reason = f'Critical error during {request_type}: {str(e)[:200]}'
                logger.error(reason)
        else:
            # If we run out of retries: set status to failed
            if not reason:
                status = cfnresponse.FAILED
                reason = f'Exceeded retries for {request_type} on bucket {bucket_name}'

    except Exception as e:
        logger.error(f'Unhandled exception in handler: {str(e)}')
        status = cfnresponse.FAILED
        reason = f'Unhandled exception: {str(e)[:200]}'
    finally:
        # Always send cfnresponse, preventing stuck stack
        cfnresponse.send(event, context, status, {}, physical_resource_id, reason=reason)
