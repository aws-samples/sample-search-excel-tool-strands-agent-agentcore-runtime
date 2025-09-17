#!/bin/bash

set -euo pipefail

# === Load environment variables ===
source "$(dirname "$0")/env.sh"

echo "=== Deploying stack for version: $VERSION ==="
echo "Region: $REGION | Profile: $PROFILE | Account: $ACCOUNT_ID"
echo "Source bucket: $SOURCE_BUCKET_NAME"
echo "Vector bucket: $VECTOR_BUCKET_NAME"
echo "ECR repo: $REPO_NAME"
echo "Vector index: $VECTOR_INDEX_NAME"
echo "Stack name: $STACK_NAME"

# ==== Build local docker images ====
echo "--- Building local Docker images ---"
docker buildx build --platform linux/amd64 --provenance=false --no-cache \
    -f Dockerfile.index -t "$REPO_NAME:index" --load .
docker buildx build --platform linux/amd64 --provenance=false --no-cache \
    -f Dockerfile.clean -t "$REPO_NAME:clean" --load .
docker buildx build --platform linux/amd64 --provenance=false --no-cache \
    -f Dockerfile.s3vectors -t "$REPO_NAME:s3vectors" --load .

# ==== Create / update ECR repository via CloudFormation ====
echo "--- Ensuring ECR repository exists ---"
cat > ecr-template.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: ECR Repository for Lambda container images
Parameters:
  EcrRepositoryName:
    Type: String
    Description: Name of the ECR repository
Resources:
  EcrRepository:
    Type: AWS::ECR::Repository
    DeletionPolicy: Delete
    Properties:
      RepositoryName: !Ref EcrRepositoryName
Outputs:
  RepositoryUri:
    Value: !GetAtt EcrRepository.RepositoryUri
    Description: URI of the ECR repository
EOF

aws cloudformation deploy \
    --stack-name "${STACK_NAME}-ecr" \
    --template-file ecr-template.yaml \
    --region "$REGION" \
    --profile "$PROFILE" \
    --parameter-overrides EcrRepositoryName="$REPO_NAME"

# ==== Push images to ECR ====
echo "--- Logging into Amazon ECR ---"
aws ecr get-login-password --region "$REGION" --profile "$PROFILE" \
    | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "--- Tagging images for ECR ---"
docker tag "$REPO_NAME:index" "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:index"
docker tag "$REPO_NAME:clean" "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:clean"
docker tag "$REPO_NAME:s3vectors" "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:s3vectors"

echo "--- Pushing images to ECR ---"
docker push "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:index"
docker push "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:clean"
docker push "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME:s3vectors"

rm -f ecr-template.yaml

# ==== Deploy main CF stack ====
echo "--- Deploying main CloudFormation stack ---"
# Spinner function
spin() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Run deploy command in the background and show spinner
aws cloudformation deploy \
    --stack-name "$STACK_NAME" \
    --template-file template.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$REGION" \
    --profile "$PROFILE" \
    --parameter-overrides \
        Version="$VERSION" \
        SourceBucketName="$SOURCE_BUCKET_NAME" \
        VectorBucketName="$VECTOR_BUCKET_NAME" \
        EcrRepositoryName="$REPO_NAME" \
        VectorIndexName="$VECTOR_INDEX_NAME" \
        EnableNotification="true" &
pid=$!
spin $pid
wait $pid
echo "Main CloudFormation stack deployment complete."

echo "✅ Deployment complete for version $VERSION."