#!/bin/bash
# Usage: ./render-sso-policy.sh env.sh sso-profile-policy.json output-sso-policy.json

set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 path/to/env.sh path/to/sso-profile-policy.json path/to/output-sso-policy.json"
  exit 1
fi

ENV_SH=$1
POLICY_INPUT=$2
POLICY_OUTPUT=$3

# Source environment for REGION, ACCOUNT_ID, and VERSION
source "$ENV_SH"

# Use sed to substitute REGION, ACCOUNT_ID, and VERSION in the policy template.
# This avoids the need for 'envsubst' (from the gettext package).
sed -e "s|\${REGION}|${REGION}|g" \
    -e "s|\${ACCOUNT_ID}|${ACCOUNT_ID}|g" \
    -e "s|\${VERSION}|${VERSION}|g" < "$POLICY_INPUT" > "$POLICY_OUTPUT"

echo "✅ Rendered policy written to $POLICY_OUTPUT"