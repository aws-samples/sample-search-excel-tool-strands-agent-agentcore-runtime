#!/bin/bash
set -e

cleanup() {
  echo "Cleaning up virtual environment only..."
  if [ -d "$VENV_DIR" ]; then
    echo "Deactivating and removing virtual environment: $VENV_DIR..."
    deactivate 2>/dev/null || true
    rm -rf "$VENV_DIR"
  fi
}
trap cleanup EXIT

cd "$(dirname "$0")" || exit 1

if [ ! -f "../env.sh" ]; then
  echo "Error: env.sh not found in parent directory."
  exit 1
fi
source ../env.sh

echo "==== DEBUG: env.sh values ==== "
echo "PROFILE=$PROFILE"
echo "VERSION=$VERSION"
echo "VECTOR_BUCKET_NAME=$VECTOR_BUCKET_NAME"
echo "VECTOR_INDEX_NAME=$VECTOR_INDEX_NAME"
echo "MODEL_ID=$MODEL_ID"
echo "REASONING_MODEL_ID=$REASONING_MODEL_ID"
echo "ACCOUNT_ID=$ACCOUNT_ID"
echo "REGION=$REGION"
echo "================================"

# Validate environment variables
echo "Validating environment variables..."
[ -z "$VECTOR_BUCKET_NAME" ] && { echo "Error: VECTOR_BUCKET_NAME not set"; exit 1; }
[ -z "$VECTOR_INDEX_NAME" ] && { echo "Error: VECTOR_INDEX_NAME not set"; exit 1; }
[ -z "$MODEL_ID" ] && { echo "Error: MODEL_ID not set"; exit 1; }
[ -z "$REASONING_MODEL_ID" ] && { echo "Error: REASONING_MODEL_ID not set"; exit 1; }
[ -z "$REGION" ] && { echo "Error: REGION not set"; exit 1; }
[ -z "$ACCOUNT_ID" ] && { echo "Error: ACCOUNT_ID not set"; exit 1; }
[ -z "$PROFILE" ] && { echo "Error: PROFILE not set"; exit 1; }
[ -z "$VERSION" ] && { echo "Error: VERSION not set"; exit 1; }

export AWS_PROFILE="$PROFILE"
export AWS_PAGER=""

aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" || {
  echo "AWS CLI creds invalid"
  exit 1
}

VENV_DIR=$(mktemp -d)
python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install bedrock-agentcore bedrock-agentcore-starter-toolkit
if [ -f "requirements.txt" ]; then pip install -r requirements.txt; fi

ECR_REPO="agentcore-repo-${VERSION}"
ECR_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$ECR_REPO"
aws ecr describe-repositories --repository-names "$ECR_REPO" --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1 || {
  aws ecr create-repository --repository-name "$ECR_REPO" --profile "$PROFILE" --region "$REGION"
}

# Clean up existing images in ECR to avoid caching
echo "Cleaning up existing images in ECR repository $ECR_REPO..."
aws ecr batch-delete-image \
  --repository-name "$ECR_REPO" \
  --image-ids imageTag=latest \
  --profile "$PROFILE" --region "$REGION" 2>/dev/null || true

ROLE_NAME="agentcoreindexstack-StrandsAgentRuntimeRole-${VERSION}"

# Trust policy 
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeRolePolicy",
      "Effect": "Allow",
      "Principal": { "Service": "bedrock-agentcore.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
        "ArnLike":      { "aws:SourceArn": "arn:aws:bedrock-agentcore:${REGION}:${ACCOUNT_ID}:*" }
      }
    }
  ]
}
EOF
)

# Derive the foundation-model ID from a profile ID (strip leading "us.")
if [[ "$REASONING_MODEL_ID" == us.* ]]; then
  FM_ID="${REASONING_MODEL_ID#us.}"
else
  FM_ID="$REASONING_MODEL_ID"
fi

# Inline policy – use heredoc so variables expand
INLINE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowBedrockReasoningSonnet4",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:InvokeModel",
        "bedrock:Converse",
        "bedrock:ConverseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/${FM_ID}",
        "arn:aws:bedrock:*:${ACCOUNT_ID}:inference-profile/${REASONING_MODEL_ID}"
      ]
    },
    {
      "Sid": "AllowEmbeddings",
      "Effect": "Allow",
      "Action": ["bedrock:InvokeModel"],
      "Resource": "arn:aws:bedrock:*::foundation-model/${MODEL_ID}"
    },
    {
      "Sid": "LogsBasic",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECRPull",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:DescribeImages"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowS3VectorsQuery",
      "Effect": "Allow",
      "Action": [
        "s3vectors:QueryVectors",
        "s3vectors:ListVectors",
        "s3vectors:GetVectors"
      ],
      "Resource": "arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${VECTOR_BUCKET_NAME}/index/${VECTOR_INDEX_NAME}"
    },
    {
      "Sid": "AllowVectorBucketRead",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::${VECTOR_BUCKET_NAME}"
    }, 
    {
      "Sid": "AllowVectorObjectsRead",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::${VECTOR_BUCKET_NAME}/*"
    },
    {
      "Sid": "PutMetricsAgentCore",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": { "StringEquals": { "cloudwatch:namespace": "bedrock-agentcore" } }
    },
    {
      "Sid": "BedrockAgentCoreAPIs",
      "Effect": "Allow",
      "Action": ["bedrock-agentcore:*"],
      "Resource": "*"
    }
  ]
}
EOF
)

echo "==== DEBUG: IAM Policy to be used ===="
echo "$INLINE_POLICY"
echo "======================================"

if ! aws iam get-role --role-name "$ROLE_NAME" --region "$REGION" --profile "$PROFILE" >/dev/null 2>&1; then
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --profile "$PROFILE" --region "$REGION"
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "StrandsAgentPolicy" \
    --policy-document "$INLINE_POLICY" \
    --profile "$PROFILE" --region "$REGION"
  sleep 30
else
  # Update existing role with new least privilege policy
  aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "StrandsAgentPolicy" \
    --policy-document "$INLINE_POLICY" \
    --profile "$PROFILE" --region "$REGION"
  sleep 30
fi

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
  --query "Role.Arn" --output text --profile "$PROFILE" --region "$REGION")
echo "==== DEBUG: ROLE ARN assigned: $ROLE_ARN"

# Remove any existing Dockerfile to avoid conflicts
rm -f Dockerfile

echo "Generating Dockerfile..."
cat > Dockerfile <<EOL
FROM --platform=linux/arm64 ghcr.io/astral-sh/uv:python3.12-bookworm-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
ENV VECTOR_BUCKET_NAME="$VECTOR_BUCKET_NAME"
ENV INDEX_NAME="$VECTOR_INDEX_NAME"
ENV MODEL_ID="$MODEL_ID"
ENV REASONING_MODEL_ID="$REASONING_MODEL_ID"
ENV AWS_REGION="$REGION"
ENV AWS_DEFAULT_REGION="$REGION"
ENV REGION="$REGION"
ENV DOCKER_CONTAINER=1
RUN echo "Environment variables in Dockerfile:" && env | grep -E 'VECTOR_BUCKET_NAME|INDEX_NAME|MODEL_ID|REASONING_MODEL_ID|AWS_REGION|REGION|DOCKER_CONTAINER' > /app/env_debug.txt
RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore
EXPOSE 8080
CMD ["uv", "run", "python", "app.py"]
EOL

echo "Generated Dockerfile content:"
cat Dockerfile

# Clear any cached build artifacts
rm -rf .bedrock_agentcore

# Create a .dockerignore to prevent unwanted files
cat > .dockerignore <<EOL
*
!app.py
!requirements.txt
!Dockerfile
!.bedrock_agentcore.yaml
EOL

# Create a temporary input file for agentcore configure OAuth prompt
INPUT_FILE=$(mktemp)
echo "no" > "$INPUT_FILE"

# Run agentcore configure with explicit ECR URI and requirements file
agentcore configure --entrypoint app.py \
  --execution-role "$ROLE_ARN" \
  --region "$REGION" \
  --ecr "$ECR_URI" \
  --requirements-file requirements.txt < "$INPUT_FILE"

# Delete the default bedrock-agentcore-app repository if created
aws ecr delete-repository \
  --repository-name bedrock-agentcore-app \
  --profile "$PROFILE" --region "$REGION" --force 2>/dev/null || true

# Replace Dockerfile with the script-generated one
echo "Replacing Dockerfile with script-generated version..."
cat > Dockerfile <<EOL
FROM --platform=linux/arm64 ghcr.io/astral-sh/uv:python3.12-bookworm-slim
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
ENV VECTOR_BUCKET_NAME="$VECTOR_BUCKET_NAME"
ENV INDEX_NAME="$VECTOR_INDEX_NAME"
ENV MODEL_ID="$MODEL_ID"
ENV REASONING_MODEL_ID="$REASONING_MODEL_ID"
ENV AWS_REGION="$REGION"
ENV AWS_DEFAULT_REGION="$REGION"
ENV REGION="$REGION"
ENV DOCKER_CONTAINER=1
RUN echo "Environment variables in Dockerfile:" && env | grep -E 'VECTOR_BUCKET_NAME|INDEX_NAME|MODEL_ID|REASONING_MODEL_ID|AWS_REGION|REGION|DOCKER_CONTAINER' > /app/env_debug.txt
RUN useradd -m -u 1000 bedrock_agentcore
USER bedrock_agentcore
EXPOSE 8080
CMD ["uv", "run", "python", "app.py"]
EOL

echo "Replaced Dockerfile content:"
cat Dockerfile

sed -i.bak "s|ecr:.*|ecr: $ECR_URI|" .bedrock_agentcore.yaml
rm -f .bedrock_agentcore.yaml.bak

echo "==== DEBUG: .bedrock_agentcore.yaml ecr set to $(grep ecr .bedrock_agentcore.yaml) ===="

# Run agentcore launch
agentcore launch --auto-update-on-conflict

# Check agent status
echo "Checking agent status..."
agentcore status

# Verify CloudWatch log group creation
echo "Verifying CloudWatch log group creation..."
aws logs describe-log-groups --log-group-name-prefix "/aws/bedrock-agentcore/runtimes/app-yGSwuh40YZ-DEFAULT" --region "$REGION" --profile "$PROFILE" || {
  echo "Warning: CloudWatch log group not found. Check Bedrock AgentCore logging configuration."
}

# Wait for deployment to be ready (up to 60 seconds)
echo "Waiting for agent to be deployed..."
for i in {1..12}; do
  STATUS=$(agentcore status | grep "STATUS:" | awk -F'STATUS: ' '{print $2}' | awk '{print $1}' | tr -d '[:space:]')
  if [ "$STATUS" = "READY" ] || [ "$STATUS" = "DEPLOYED" ]; then
    echo "Agent is deployed! Status: $STATUS"
    break
  fi
  echo "Agent status: $STATUS, waiting 5 seconds..."
  sleep 5
done

if [ "$STATUS" != "READY" ] && [ "$STATUS" != "DEPLOYED" ]; then
  echo "Error: Agent not deployed after 60 seconds. Check CloudWatch logs for details."
  exit 1
fi

# Run agentcore invoke
agentcore invoke '{"prompt": "agentic AI security for CISO"}'
echo "Deployment complete!"