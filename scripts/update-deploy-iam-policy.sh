#!/usr/bin/env bash
#
# Pushes docs/deploy-iam-policy.json as an inline policy on the deployer
# IAM role (default: tfeDemo219Role), so the role's permissions stay in
# sync with what's committed in this repo.
#
# This updates the *existing* role in place (iam:PutRolePolicy) — it does
# NOT create a new role. You only need a new role if you don't have
# permission to modify this one, or if org policy requires immutable
# roles; neither applies here.
#
# Usage:
#   ./scripts/update-deploy-iam-policy.sh [role-name] [policy-name]
#
#   role-name   defaults to tfeDemo219Role
#   policy-name defaults to tfeDemo219RolePolicy (the inline policy's
#               existing name on the role, so this updates it in place
#               instead of adding a second, redundant inline policy)
#
# Requires: aws CLI (with credentials that can iam:GetRole /
# iam:PutRolePolicy on the target role), and either jq or python3 (for a
# local JSON syntax check before pushing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_FILE="$REPO_ROOT/docs/deploy-iam-policy.json"

ROLE_NAME="${1:-tfeDemo219Role}"
POLICY_NAME="${2:-tfeDemo219RolePolicy}"

for bin in aws; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "ERROR: policy file not found: $POLICY_FILE" >&2
  exit 1
fi

echo "==> [1/3] Validating JSON syntax: $POLICY_FILE"
if command -v jq >/dev/null 2>&1; then
  jq empty "$POLICY_FILE"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$POLICY_FILE"
else
  echo "WARNING: neither 'jq' nor 'python3' found; skipping local JSON validation." >&2
fi

echo "==> [2/3] Confirming role exists: $ROLE_NAME"
aws iam get-role --role-name "$ROLE_NAME" >/dev/null

echo "==> [3/3] Pushing inline policy '$POLICY_NAME' to role '$ROLE_NAME'"
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://$POLICY_FILE"

echo
echo "==> Done. Verify with:"
echo "    aws iam get-role-policy --role-name $ROLE_NAME --policy-name $POLICY_NAME"
