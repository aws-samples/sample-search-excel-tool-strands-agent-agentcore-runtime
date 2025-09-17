#!/bin/bash

# Script to clean up resources created by deploy-app-to-agentcore-runtime.sh
# Usage: bash cleanup_agentcore_runtime.sh
# Assumes AWS CLI is configured and env.sh exists in parent directory
# Deletes Bedrock AgentCore agent, IAM roles, policies, ECR repositories, S3 bucket, CodeBuild project, and local configuration files

# Step 1: Set working directory to script location
cd "$(dirname "$0")" || exit 1

# Step 2: Source env.sh
if [ ! -f "../env.sh" ]; then
  echo "Error: env.sh not found in parent directory."
  exit 1
fi
source ../env.sh
echo "Sourced env.sh: PROFILE=$PROFILE, VERSION=$VERSION, ACCOUNT_ID=$ACCOUNT_ID, REGION=$REGION"

# Step 3: Validate required environment variables
if [ -z "$ACCOUNT_ID" ] || [ -z "$PROFILE" ] || [ -z "$VERSION" ] || [ -z "$REGION" ]; then
  echo "Error: Required variables (PROFILE, VERSION, ACCOUNT_ID, REGION) not set."
  exit 1
fi

# Step 4: Export AWS profile and disable pager
export AWS_PROFILE="$PROFILE"
export AWS_PAGER=""

# Step 5: Delete Bedrock AgentCore agent
AGENT_NAME="app"
echo "Checking for Bedrock AgentCore agent: $AGENT_NAME..."
AGENT_ID=$(aws bedrock-agent list-agents --query "agentSummaries[?agentName=='$AGENT_NAME'].agentId" --output text --profile "$PROFILE" --region "$REGION" 2>/dev/null)
if [ -n "$AGENT_ID" ]; then
  echo "Deleting Bedrock AgentCore agent: $AGENT_NAME (ID: $AGENT_ID)..."
  aws bedrock-agent delete-agent --agent-id "$AGENT_ID" --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete Bedrock AgentCore agent."
  fi
else
  echo "Bedrock AgentCore agent $AGENT_NAME does not exist."
fi

# Step 6: Delete IAM role and policy for agent
ROLE_NAME="StrandsAgentRuntimeRole-${VERSION}"
echo "Checking for IAM role: $ROLE_NAME..."
aws iam get-role --role-name "$ROLE_NAME" --profile "$PROFILE" --region "$REGION" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Deleting IAM role policy: StrandsAgentPolicy..."
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "StrandsAgentPolicy" --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete IAM role policy."
  fi
  echo "Deleting IAM role: $ROLE_NAME..."
  aws iam delete-role --role-name "$ROLE_NAME" --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete IAM role."
  fi
else
  echo "IAM role $ROLE_NAME does not exist."
fi

# Step 7: Delete CodeBuild IAM role and policy
CODEBUILD_ROLE_NAME="AmazonBedrockAgentCoreSDKCodeBuild-us-east-1-a172cedcae"
echo "Checking for CodeBuild IAM role: $CODEBUILD_ROLE_NAME..."
aws iam get-role --role-name "$CODEBUILD_ROLE_NAME" --profile "$PROFILE" --region "$REGION" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Deleting CodeBuild IAM role policy: CodeBuildExecutionPolicy..."
  aws iam delete-role-policy --role-name "$CODEBUILD_ROLE_NAME" --policy-name "CodeBuildExecutionPolicy" --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete CodeBuild IAM role policy."
  fi
  echo "Waiting for IAM role propagation..."
  sleep 10
  echo "Deleting CodeBuild IAM role: $CODEBUILD_ROLE_NAME..."
  aws iam delete-role --role-name "$CODEBUILD_ROLE_NAME" --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete CodeBuild IAM role."
  fi
else
  echo "CodeBuild IAM role $CODEBUILD_ROLE_NAME does not exist."
fi

# Step 8: Delete ECR repository for agent
ECR_REPO="agentcore-repo-${VERSION}"
echo "Checking for ECR repository: $ECR_REPO..."
aws ecr describe-repositories --repository-names "$ECR_REPO" --profile "$PROFILE" --region "$REGION" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Deleting ECR repository: $ECR_REPO..."
  aws ecr delete-repository --repository-name "$ECR_REPO" --force --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete ECR repository."
  fi
else
  echo "ECR repository $ECR_REPO does not exist."
fi

# Step 9: Delete CodeBuild ECR repository
CODEBUILD_ECR_REPO="bedrock-agentcore-app"
echo "Checking for CodeBuild ECR repository: $CODEBUILD_ECR_REPO..."
aws ecr describe-repositories --repository-names "$CODEBUILD_ECR_REPO" --profile "$PROFILE" --region "$REGION" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Deleting CodeBuild ECR repository: $CODEBUILD_ECR_REPO..."
  aws ecr delete-repository --repository-name "$CODEBUILD_ECR_REPO" --force --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete CodeBuild ECR repository."
  fi
else
  echo "CodeBuild ECR repository $CODEBUILD_ECR_REPO does not exist."
fi

# Step 10: Delete CodeBuild project
CODEBUILD_PROJECT="bedrock-agentcore-app-builder"
echo "Checking for CodeBuild project: $CODEBUILD_PROJECT..."
aws codebuild list-projects --query "projects[?@=='$CODEBUILD_PROJECT']" --output text --profile "$PROFILE" --region "$REGION" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Deleting CodeBuild project: $CODEBUILD_PROJECT..."
  aws codebuild delete-project --name "$CODEBUILD_PROJECT" --profile "$PROFILE" --region "$REGION" 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete CodeBuild project."
  fi
else
  echo "CodeBuild project $CODEBUILD_PROJECT does not exist."
fi

# Step 11: Delete CodeBuild S3 bucket with retry
CODEBUILD_S3_BUCKET="bedrock-agentcore-codebuild-sources-541474745272-us-east-1"
echo "Checking for CodeBuild S3 bucket: $CODEBUILD_S3_BUCKET..."
aws s3 ls "s3://$CODEBUILD_S3_BUCKET" --profile "$PROFILE" --region "$REGION" 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Emptying and deleting CodeBuild S3 bucket: $CODEBUILD_S3_BUCKET..."
  for attempt in {1..3}; do
    aws s3 rm "s3://$CODEBUILD_S3_BUCKET" --recursive --profile "$PROFILE" --region "$REGION" 2>/dev/null
    aws s3 rb "s3://$CODEBUILD_S3_BUCKET" --force --profile "$PROFILE" --region "$REGION" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "Successfully deleted CodeBuild S3 bucket."
      break
    fi
    echo "Retrying S3 bucket deletion (attempt $attempt)..."
    sleep 5
  done
  if [ $? -ne 0 ]; then
    echo "Warning: Failed to delete CodeBuild S3 bucket after retries."
  fi
else
  echo "CodeBuild S3 bucket $CODEBUILD_S3_BUCKET does not exist."
fi

# Step 12: Delete local configuration files
echo "Removing local configuration files to prevent mismatches..."
rm -rf .bedrock_agentcore .bedrock_agentcore.yaml .dockerignore Dockerfile 2>/dev/null
if [ $? -eq 0 ]; then
  echo "Successfully removed local configuration files."
else
  echo "No local configuration files found."
fi

echo "Cleanup complete!"