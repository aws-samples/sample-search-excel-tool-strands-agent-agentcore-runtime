#!/bin/bash

export VERSION="v50"

export REGION="us-east-1"
export PROFILE="least_privilege_search_video-541474745272"
export ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)

export SOURCE_BUCKET_NAME="agentcore-source-bucket-${ACCOUNT_ID}-${VERSION}"
export VECTOR_BUCKET_NAME="agentcore-vector-bucket-${ACCOUNT_ID}-${VERSION}"
export REPO_NAME="agentcore-indexing-repo-${ACCOUNT_ID}-${VERSION}"
export STACK_NAME="agentcoreindexstack-${VERSION}"
export VECTOR_INDEX_NAME="transcript-index-${VERSION}"
export MODEL_ID="amazon.titan-embed-text-v2:0"
#export REASONING_MODEL_ID="us.anthropic.claude-3-7-sonnet-20250219-v1:0"
export REASONING_MODEL_ID="us.anthropic.claude-sonnet-4-20250514-v1:0"
export MAX_WAIT_ATTEMPTS=60
export POLL_INTERVAL=10
