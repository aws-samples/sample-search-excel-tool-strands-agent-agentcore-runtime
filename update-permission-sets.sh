#!/bin/bash

set -euo pipefail
set -x  # Debug

# === Configuration ===
SSO_PROFILE="AdministratorAccess-541474745272"
REGION="us-east-1"
POLICY_INPUT="sso-profile-policy.json"
POLICY_OUTPUT="output-policy.json"
ENV_SH="env.sh"
USER_NAME="ramanira_lp"
MAX_WAIT_ATTEMPTS=10
POLL_INTERVAL=30

# === Validate inputs ===
if [[ ! -f "$ENV_SH" ]]; then
    echo "Error: $ENV_SH not found."
    exit 1
fi
if [[ ! -f "$POLICY_INPUT" ]]; then
    echo "Error: $POLICY_INPUT not found."
    exit 1
fi

# === Load env vars ===
source "$ENV_SH"

# === Render the policy ===
echo "Rendering $POLICY_INPUT to $POLICY_OUTPUT..."
./render-sso-policy.sh "$ENV_SH" "$POLICY_INPUT" "$POLICY_OUTPUT"

# === Get SSO instance ARN and Identity Store ID ===
echo "Fetching SSO instance ARN and Identity Store ID..."
SSO_INSTANCE_INFO=$(aws sso-admin list-instances \
    --region "$REGION" \
    --profile "$SSO_PROFILE" \
    --query 'Instances[0].{InstanceArn:InstanceArn,IdentityStoreId:IdentityStoreId}' \
    --output json \
    --no-cli-pager)
if [[ -z "$SSO_INSTANCE_INFO" || "$SSO_INSTANCE_INFO" == "{}" ]]; then
    echo "Error: No SSO instance found in region $REGION."
    exit 1
fi
SSO_INSTANCE_ARN=$(echo "$SSO_INSTANCE_INFO" | jq -r '.InstanceArn')
IDENTITY_STORE_ID=$(echo "$SSO_INSTANCE_INFO" | jq -r '.IdentityStoreId')
echo "SSO instance ARN: $SSO_INSTANCE_ARN"
echo "Identity Store ID: $IDENTITY_STORE_ID"

# === Get PrincipalId for the user ===
echo "Fetching PrincipalId for user $USER_NAME..."
PRINCIPAL_ID=$(aws identitystore list-users \
    --identity-store-id "$IDENTITY_STORE_ID" \
    --region "$REGION" \
    --profile "$SSO_PROFILE" \
    --query "Users[?UserName==\`$USER_NAME\`].UserId" \
    --output text \
    --no-cli-pager)
if [[ -z "$PRINCIPAL_ID" ]]; then
    echo "Error: No user found with username $USER_NAME in Identity Store $IDENTITY_STORE_ID."
    exit 1
fi
echo "PrincipalId for $USER_NAME: $PRINCIPAL_ID"

# === Get permission set ARN for the user ===
echo "Fetching permission sets for user $USER_NAME (PrincipalId: $PRINCIPAL_ID)..."
PERMISSION_SET_ARNS=$(aws sso-admin list-permission-sets \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --region "$REGION" \
    --profile "$SSO_PROFILE" \
    --query 'PermissionSets[]' \
    --output text \
    --no-cli-pager)
if [[ -z "$PERMISSION_SET_ARNS" ]]; then
    echo "Error: No permission sets found for instance $SSO_INSTANCE_ARN."
    exit 1
fi

PERMISSION_SET_ARN=""
for arn in $PERMISSION_SET_ARNS; do
    assignments=$(aws sso-admin list-account-assignments \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --account-id "$ACCOUNT_ID" \
        --permission-set-arn "$arn" \
        --region "$REGION" \
        --profile "$SSO_PROFILE" \
        --query "AccountAssignments[?PrincipalId==\`$PRINCIPAL_ID\`].PermissionSetArn" \
        --output text \
        --no-cli-pager)
    if [[ -n "$assignments" ]]; then
        PERMISSION_SET_ARN="$arn"
        break
    fi
done

if [[ -z "$PERMISSION_SET_ARN" ]]; then
    echo "Error: No permission set found for user $USER_NAME (PrincipalId: $PRINCIPAL_ID) in account $ACCOUNT_ID."
    exit 1
fi
echo "Permission set ARN: $PERMISSION_SET_ARN"

# === Update the permission set with inline policy ===
echo "Updating permission set $PERMISSION_SET_ARN with $POLICY_OUTPUT..."
aws sso-admin put-inline-policy-to-permission-set \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --inline-policy file://"$POLICY_OUTPUT" \
    --region "$REGION" \
    --profile "$SSO_PROFILE" \
    --no-cli-pager || {
    echo "Error: Failed to update permission set $PERMISSION_SET_ARN."
    exit 1
}

# === Start and wait for account assignment propagation ===
echo "Starting account assignment creation..."
CREATE_STATUS=$(aws sso-admin create-account-assignment \
    --instance-arn "$SSO_INSTANCE_ARN" \
    --target-id "$ACCOUNT_ID" \
    --target-type "AWS_ACCOUNT" \
    --permission-set-arn "$PERMISSION_SET_ARN" \
    --principal-id "$PRINCIPAL_ID" \
    --principal-type "USER" \
    --region "$REGION" \
    --profile "$SSO_PROFILE" \
    --query 'AccountAssignmentCreationStatus' \
    --output json \
    --no-cli-pager)
STATUS_ID=$(echo "$CREATE_STATUS" | jq -r '.RequestId')

echo "Waiting for policy propagation to complete..."
for (( i=1; i<=$MAX_WAIT_ATTEMPTS; i++ )); do
    STATUS_CHECK=$(aws sso-admin describe-account-assignment-creation-status \
        --instance-arn "$SSO_INSTANCE_ARN" \
        --account-assignment-creation-request-id "$STATUS_ID" \
        --region "$REGION" \
        --profile "$SSO_PROFILE" \
        --query 'AccountAssignmentCreationStatus.Status' \
        --output text \
        --no-cli-pager)

    if [[ "$STATUS_CHECK" == "SUCCEEDED" ]]; then
        echo "✅ Policy propagation succeeded."
        break
    elif [[ "$STATUS_CHECK" == "FAILED" ]]; then
        echo "Error: Policy propagation failed."
        exit 1
    fi
    echo "Status: $STATUS_CHECK. Waiting $POLL_INTERVAL seconds... (Attempt $i of $MAX_WAIT_ATTEMPTS)"
    sleep $POLL_INTERVAL
done

if [[ "$STATUS_CHECK" != "SUCCEEDED" ]]; then
    echo "Error: Policy propagation timed out."
    exit 1
fi

echo "✅ Script completed successfully."