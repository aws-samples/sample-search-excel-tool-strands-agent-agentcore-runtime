#!/bin/bash

set -euo pipefail
set -x  # Debug

# Disable AWS CLI pagination
export AWS_PAGER=""

# === Load env vars ===
source "$(dirname "$0")/env.sh"

# Define variables early
export SQS_QUEUE_NAME="agentcore-dlq-${VERSION}"
export LOGGING_BUCKET="agentcore-source-logs-${ACCOUNT_ID}-${VERSION}"

echo "Cleaning up resources for version $VERSION ..."
echo "PROFILE=$PROFILE REGION=$REGION"
echo "SOURCE_BUCKET_NAME=$SOURCE_BUCKET_NAME"
echo "VECTOR_BUCKET_NAME=$VECTOR_BUCKET_NAME"
echo "LOGGING_BUCKET=$LOGGING_BUCKET"
echo "STACK_NAME=$STACK_NAME"
echo "REPO_NAME=$REPO_NAME"
echo "VECTOR_INDEX_NAME=$VECTOR_INDEX_NAME"
echo "SQS_QUEUE_NAME=$SQS_QUEUE_NAME"

# === Helper: Empty a versioned S3 bucket ===
empty_bucket_all_versions() {
    local bucket=$1
    echo "Purging all versions and delete markers from bucket: $bucket"
    if aws s3api head-bucket --bucket "$bucket" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null; then
        versions=$(aws s3api list-object-versions --bucket "$bucket" --region "$REGION" --profile "$PROFILE" --query='{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json --no-cli-pager)
        if [[ $(echo "$versions" | jq '.Objects | length') -gt 0 ]]; then
            echo "$versions" > /tmp/versions.json
            aws s3api delete-objects --bucket "$bucket" --delete file:///tmp/versions.json --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete object versions for $bucket"
        fi
        markers=$(aws s3api list-object-versions --bucket "$bucket" --region "$REGION" --profile "$PROFILE" --query='{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json --no-cli-pager)
        if [[ $(echo "$markers" | jq '.Objects | length') -gt 0 ]]; then
            echo "$markers" > /tmp/markers.json
            aws s3api delete-objects --bucket "$bucket" --delete file:///tmp/markers.json --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete markers for $bucket"
        fi
        aws s3 rb "s3://$bucket" --force --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete bucket $bucket"
    else
        echo "Bucket $bucket does not exist."
    fi
}

# === Helper: Detach policies from a role ===
detach_role_policies() {
    local role=$1
    policies=$(aws iam list-attached-role-policies --role-name "$role" --region "$REGION" --profile "$PROFILE" --query 'AttachedPolicies[].PolicyArn' --output text --no-cli-pager 2>/dev/null || echo "")
    for policy in $policies; do
        echo "Detaching policy $policy from role $role"
        aws iam detach-role-policy --role-name "$role" --policy-arn "$policy" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to detach policy $policy from $role"
    done
}

# === Helper: Delete CloudFormation stack ===
delete_stack() {
    local stack_name=$1
    if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --profile "$PROFILE" --no-cli-pager >/dev/null 2>&1; then
        local stack_status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" --profile "$PROFILE" --query 'Stacks[0].StackStatus' --output text --no-cli-pager)
        
        echo "Deleting CloudFormation stack: $stack_name (Status: $stack_status)"
        
        # Check if the stack is in a state where we can use --retain-resources
        if [[ "$stack_status" == "DELETE_FAILED" ]]; then
            RETAINED_RESOURCES=$(aws cloudformation describe-stack-resources \
                --stack-name "$stack_name" \
                --region "$REGION" \
                --profile "$PROFILE" \
                --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
                --output text --no-cli-pager 2>/dev/null)
            
            if [ -n "$RETAINED_RESOURCES" ]; then
                echo "Retained resources found in DELETE_FAILED state: $RETAINED_RESOURCES. Attempting to delete stack..."
                aws cloudformation delete-stack --stack-name "$stack_name" --retain-resources $RETAINED_RESOURCES --region "$REGION" --profile "$PROFILE" --no-cli-pager
            else
                echo "No DELETE_FAILED resources found. Attempting regular stack deletion..."
                aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION" --profile "$PROFILE" --no-cli-pager
            fi
        # For other statuses (like ROLLBACK_FAILED), try to delete normally without --retain-resources
        else
            echo "Stack is not in DELETE_FAILED state. Attempting regular stack deletion..."
            aws cloudformation delete-stack --stack-name "$stack_name" --region "$REGION" --profile "$PROFILE" --no-cli-pager
        fi
        
        # Wait for deletion to complete. This will fail if a resource is truly stuck.
        aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$REGION" --profile "$PROFILE" --no-cli-pager || {
            echo "Manual cleanup may be required for retained resources in stack $stack_name."
            return 1
        }
    else
        echo "Stack $stack_name does not exist."
    fi
}

# === Helper: Delete KMS key ===
handle_kms_key() {
    local key_id=$1
    if aws kms describe-key --key-id "$key_id" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null; then
        echo "Scheduling deletion for KMS key: $key_id"
        aws kms schedule-key-deletion --key-id "$key_id" --pending-window-in-days 7 --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to schedule deletion for KMS key $key_id"
    else
        echo "KMS key $key_id does not exist."
    fi
}

# === Helper: Delete ECR repository ===
delete_ecr_repository() {
    local repo_name=$1
    if aws ecr describe-repositories --repository-names "$repo_name" --region "$REGION" --profile "$PROFILE" --no-cli-pager >/dev/null 2>&1; then
        echo "Deleting images in ECR repository: $repo_name"
        images=$(aws ecr list-images --repository-name "$repo_name" --region "$REGION" --profile "$PROFILE" --query 'imageIds[].imageDigest' --output text --no-cli-pager 2>/dev/null || echo "")
        for image in $images; do
            aws ecr batch-delete-image --repository-name "$repo_name" --image-ids imageDigest="$image" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete image $image in $repo_name"
        done
        echo "Deleting ECR repository: $repo_name"
        aws ecr delete-repository --repository-name "$repo_name" --force --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete ECR repository $repo_name"
    else
        echo "ECR repository $repo_name does not exist."
    fi
}

# === 1. Empty existing LoggingBucket to prevent AlreadyExists errors ===
empty_bucket_all_versions "$LOGGING_BUCKET"

# === 2. Get all buckets created by the stack ===
STACK_BUCKETS=$(aws cloudformation describe-stack-resources --stack-name "$STACK_NAME" --region "$REGION" --profile "$PROFILE" --query 'StackResources[?ResourceType==`AWS::S3::Bucket`].PhysicalResourceId' --output text --no-cli-pager 2>/dev/null || echo "")
for bucket in $STACK_BUCKETS; do
    empty_bucket_all_versions "$bucket"
done

# === 3. Delete retained vector buckets and indices ===
VECTOR_BUCKETS=$(aws s3vectors list-vector-buckets --region "$REGION" --profile "$PROFILE" --query 'vectorBuckets[].bucketName' --output text --no-cli-pager 2>/dev/null || echo "")
for bucket in $VECTOR_BUCKETS; do
    if [[ $bucket == *"${VECTOR_BUCKET_NAME}"* || $bucket == *"${VECTOR_BUCKET_NAME}-${VERSION}"* ]]; then
        echo "Deleting retained vector index: $VECTOR_INDEX_NAME in bucket $bucket"
        aws s3vectors delete-index --vector-bucket-name "$bucket" --index-name "$VECTOR_INDEX_NAME" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete index $VECTOR_INDEX_NAME in $bucket"
        echo "Deleting retained vector bucket: $bucket"
        aws s3vectors delete-vector-bucket --vector-bucket-name "$bucket" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete vector bucket $bucket"
    fi
done

# === 4. Delete retained custom index resource ===
echo "Deleting retained custom index: $VECTOR_INDEX_NAME in bucket agentcore-vector-${ACCOUNT_ID}-${VERSION}"
aws s3vectors delete-index --vector-bucket-name "agentcore-vector-${ACCOUNT_ID}-${VERSION}" --index-name "$VECTOR_INDEX_NAME" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null || echo "Failed to delete custom index $VECTOR_INDEX_NAME"

# === 5. Delete retained vector bucket ===
echo "Deleting retained vector bucket: agentcore-vector-${ACCOUNT_ID}-${VERSION}"
aws s3vectors delete-vector-bucket --vector-bucket-name "agentcore-vector-${ACCOUNT_ID}-${VERSION}" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null || echo "Failed to delete retained vector bucket agentcore-vector-${ACCOUNT_ID}-${VERSION}"

# === 6. Delete KMS key for the current stack ===
KMS_KEY=$(aws cloudformation describe-stack-resources --stack-name "$STACK_NAME" --region "$REGION" --profile "$PROFILE" --query 'StackResources[?ResourceType==`AWS::KMS::Key`].PhysicalResourceId' --output text --no-cli-pager 2>/dev/null || echo "")
if [ -n "$KMS_KEY" ]; then
    handle_kms_key "$KMS_KEY"
fi

# === 7. Delete Lambda functions ===
LAMBDAS=$(aws lambda list-functions --region "$REGION" --profile "$PROFILE" --query 'Functions[?contains(FunctionName, `'"$STACK_NAME"'`)].FunctionName' --output text --no-cli-pager 2>/dev/null || echo "")
for lambda in $LAMBDAS; do
    if aws lambda get-function --function-name "$lambda" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null; then
        echo "Deleting Lambda function: $lambda"
        aws lambda delete-function --function-name "$lambda" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete Lambda function $lambda"
    else
        echo "Lambda function $lambda does not exist."
    fi
done

# === 8. Delete IAM roles ===
ROLES=$(aws iam list-roles --region "$REGION" --profile "$PROFILE" --query 'Roles[?contains(RoleName, `'"$STACK_NAME"'`)].RoleName' --output text --no-cli-pager 2>/dev/null || echo "")
for role in $ROLES; do
    if aws iam get-role --role-name "$role" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null; then
        detach_role_policies "$role"
        echo "Deleting IAM role: $role"
        aws iam delete-role --role-name "$role" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete IAM role $role"
    else
        echo "IAM role $role does not exist."
    fi
done

# === 9. Delete IAM policies ===
POLICIES=$(aws iam list-policies --region "$REGION" --profile "$PROFILE" --query 'Policies[?contains(PolicyName, `'"$STACK_NAME"'`)].Arn' --output text --no-cli-pager 2>/dev/null || echo "")
for policy in $POLICIES; do
    if aws iam get-policy --policy-arn "$policy" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null; then
        echo "Deleting IAM policy: $policy"
        aws iam delete-policy --policy-arn "$policy" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete IAM policy $policy"
    else
        echo "IAM policy $policy does not exist."
    fi
done

# === 10. Delete SQS queue ===
SQS_QUEUE_URL=$(aws sqs get-queue-url --queue-name "$SQS_QUEUE_NAME" --region "$REGION" --profile "$PROFILE" --query QueueUrl --output text --no-cli-pager 2>/dev/null || echo "")
if [ -n "$SQS_QUEUE_URL" ]; then
    echo "Deleting SQS queue: $SQS_QUEUE_URL"
    aws sqs delete-queue --queue-url "$SQS_QUEUE_URL" --region "$REGION" --profile "$PROFILE" --no-cli-pager || echo "Failed to delete SQS queue $SQS_QUEUE_NAME"
else
    echo "SQS queue $SQS_QUEUE_NAME does not exist."
fi

# === 11. Handle stuck main stack ===
delete_stack "$STACK_NAME"

# === 12. Delete ECR repository ===
delete_ecr_repository "$REPO_NAME"

# === 13. Delete CloudFormation stacks ===
STACKS=$(aws cloudformation list-stacks --region "$REGION" --profile "$PROFILE" --query 'StackSummaries[?contains(StackName, `'"$STACK_NAME"'`) && StackStatus!=`DELETE_COMPLETE`].StackName' --output text --no-cli-pager 2>/dev/null || echo "")
for stack in $STACKS; do
    delete_stack "$stack" || {
        echo "Manual cleanup may be required for retained resources in stack $stack."
    }
done

# === 14. Final bucket cleanup ===
for bucket in "$SOURCE_BUCKET_NAME" "$VECTOR_BUCKET_NAME" "${SOURCE_BUCKET_NAME}-${ACCOUNT_ID}-${VERSION}" "${VECTOR_BUCKET_NAME}-${ACCOUNT_ID}-${VERSION}"; do
    if aws s3api head-bucket --bucket "$bucket" --region "$REGION" --profile "$PROFILE" --no-cli-pager 2>/dev/null; then
        echo "Final S3 bucket removal: $bucket"
        empty_bucket_all_versions "$bucket"
    else
        echo "Bucket $bucket does not exist."
    fi
done

echo "✅ Cleanup complete for version $VERSION."