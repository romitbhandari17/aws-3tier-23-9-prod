#!/usr/bin/env bash
#
# Tears down the demo environment cleanly and reliably.
#
# Why this exists (not just `terraform destroy`): when the ECS service still
# has a running task, calling `terraform destroy` directly can race —
# Terraform asks ECS to delete the service, but the outgoing task's ENI can
# take a minute or two to fully detach, and Terraform may then try to
# delete that task's security group while the ENI is still attached,
# failing with:
#   "DependencyViolation: resource sg-... has a dependent object"
# This script avoids the race by explicitly scaling the ECS service to 0
# and waiting for it to actually reach a stable, empty state *before*
# calling `terraform destroy` at all.
#
# Usage:
#   ./scripts/destroy-infra.sh [tfvars-file]
#
# tfvars-file is relative to src/infra and defaults to envs/dev/dev.tfvars.
#
# Requires: terraform, aws CLI (with credentials configured).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFRA_DIR="$REPO_ROOT/src/infra"
TFVARS_FILE="${1:-envs/dev/dev.tfvars}"

for bin in terraform aws; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done

if [[ ! -f "$INFRA_DIR/$TFVARS_FILE" ]]; then
  echo "ERROR: tfvars file not found: $INFRA_DIR/$TFVARS_FILE" >&2
  exit 1
fi

echo "==> [1/4] terraform init"
terraform -chdir="$INFRA_DIR" init -input=false

# Read the cluster/service names from Terraform outputs so this doesn't
# hardcode the project/environment naming convention. Tolerate failure
# (e.g. state already partially destroyed, or outputs not present) and
# just skip straight to `terraform destroy` in that case.
CLUSTER_NAME="$(terraform -chdir="$INFRA_DIR" output -raw ecs_cluster_name 2>/dev/null || true)"
SERVICE_NAME="$(terraform -chdir="$INFRA_DIR" output -raw ecs_service_name 2>/dev/null || true)"

if [[ -n "$CLUSTER_NAME" && -n "$SERVICE_NAME" ]]; then
  echo "==> [2/4] Draining ECS service '$SERVICE_NAME' in cluster '$CLUSTER_NAME' to 0 tasks"
  if aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
      --query 'services[0].status' --output text 2>/dev/null | grep -q ACTIVE; then
    aws ecs update-service \
      --cluster "$CLUSTER_NAME" \
      --service "$SERVICE_NAME" \
      --desired-count 0 \
      --no-cli-pager >/dev/null

    echo "    waiting for tasks to fully drain (this can take 1-2 minutes)..."
    aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME"
    echo "    drained."
  else
    echo "    service not found or not ACTIVE; skipping drain."
  fi
else
  echo "==> [2/4] Skipping ECS drain (no ecs_cluster_name/ecs_service_name outputs found — nothing deployed yet?)"
fi

echo "==> [3/4] terraform destroy"
terraform -chdir="$INFRA_DIR" destroy -input=false -auto-approve -var-file="$TFVARS_FILE"

echo "==> [4/4] Done."
