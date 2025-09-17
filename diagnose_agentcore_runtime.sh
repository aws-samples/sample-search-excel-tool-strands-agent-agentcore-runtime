#!/bin/bash
set -e

source ./env.sh
export PROFILE="AdministratorAccess-541474745272"

echo "Checking AWS credentials..."
aws sts get-caller-identity --profile AdministratorAccess-541474745272 --region "$REGION"

echo "Checking ECR repository..."
aws ecr describe-repositories --repository-names agentcore-repo-${VERSION} --region "$REGION" --profile "$PROFILE"

echo "Checking IAM role..."
aws iam get-role --role-name agentcoreindexstack-StrandsAgentRuntimeRole-${VERSION} --region "$REGION" --profile "$PROFILE"
aws iam get-role-policy --role-name agentcoreindexstack-StrandsAgentRuntimeRole-${VERSION} --policy-name StrandsAgentPolicy --region "$REGION" --profile "$PROFILE"

echo "Checking CloudWatch log group..."
aws logs describe-log-groups --log-group-name-prefix /aws/bedrock-agentcore/runtimes/app-yGSwuh40YZ-DEFAULT --region "$REGION" --profile "$PROFILE"

echo "Checking recent log streams..."
aws logs describe-log-streams --log-group-name /aws/bedrock-agentcore/runtimes/app-yGSwuh40YZ-DEFAULT --region "$REGION" --profile "$PROFILE"

echo "Checking S3 bucket..."
aws s3 ls s3://$VECTOR_BUCKET_NAME/ --region "$REGION" --profile "$PROFILE"

echo "Checking Bedrock AgentCore workload..."
aws bedrock-agentcore list-workloads --region "$REGION" --profile "$PROFILE"

echo "Testing agentcore status..."
agentcore status

echo "Testing invoke..."
agentcore invoke '{"prompt": "I want to present to an engineer on MCP authorization"}'