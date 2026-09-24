#!/usr/bin/env bash
#
# Builds the Flask app image, pushes it to ECR, then runs `terraform apply`
# with the new image tag so ECS rolls out via a normal Terraform-managed
# deployment (new task definition revision + service update) — no
# out-of-band `aws ecs update-service --force-new-deployment` needed.
#
# Run this any time something under src/ecs/app changes (or the ECS
# module itself), instead of doing `docker build/push` + `terraform apply`
# by hand.
#
# Usage:
#   ./scripts/deploy-ecs.sh [tfvars-file]
#
# tfvars-file is relative to src/infra and defaults to envs/dev/dev.tfvars.
# AWS_REGION env var overrides the default region (us-east-1).
#
# Requires: terraform, docker, aws CLI (with credentials configured), git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INFRA_DIR="$REPO_ROOT/src/infra"
APP_DIR="$REPO_ROOT/src/ecs/app"
TFVARS_FILE="${1:-envs/dev/dev.tfvars}"
AWS_REGION="${AWS_REGION:-us-east-1}"

for bin in terraform docker aws git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done

if [[ ! -f "$INFRA_DIR/$TFVARS_FILE" ]]; then
  echo "ERROR: tfvars file not found: $INFRA_DIR/$TFVARS_FILE" >&2
  exit 1
fi

# Tag images with the current commit SHA so every deploy is traceable and
# forces a new task definition revision (a "latest" re-push alone would not
# change the task definition, so ECS wouldn't redeploy).
IMAGE_TAG="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
if ! git -C "$REPO_ROOT" diff --quiet -- "$APP_DIR" 2>/dev/null; then
  IMAGE_TAG="${IMAGE_TAG}-dirty"
fi

echo "==> [1/5] terraform init"
terraform -chdir="$INFRA_DIR" init -input=false

echo "==> [2/5] terraform apply (ensures ECR repo + infra exist before we push)"
terraform -chdir="$INFRA_DIR" apply -input=false -auto-approve -var-file="$TFVARS_FILE"

ECR_REPO_URL="$(terraform -chdir="$INFRA_DIR" output -raw ecr_repository_url)"
ECR_REGISTRY="${ECR_REPO_URL%%/*}"

echo "==> [3/5] docker login to $ECR_REGISTRY"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "==> [3/5] docker build: $ECR_REPO_URL:$IMAGE_TAG"
# ECS Fargate defaults to linux/amd64. Force that platform explicitly so
# this still produces a runnable image when built on Apple Silicon (arm64)
# or any other non-amd64 host — otherwise you'll hit
# "CannotPullContainerError: ... does not contain descriptor matching
# platform 'linux/amd64'" at task launch.
docker build \
  --platform linux/amd64 \
  -t "$ECR_REPO_URL:$IMAGE_TAG" \
  -t "$ECR_REPO_URL:latest" \
  "$APP_DIR"

echo "==> [4/5] docker push: $IMAGE_TAG, latest"
docker push "$ECR_REPO_URL:$IMAGE_TAG"
docker push "$ECR_REPO_URL:latest"

echo "==> [5/5] terraform apply -var image_tag=$IMAGE_TAG (triggers ECS rolling deployment)"
terraform -chdir="$INFRA_DIR" apply -input=false -auto-approve \
  -var-file="$TFVARS_FILE" \
  -var="image_tag=$IMAGE_TAG"

echo
echo "==> Done."
echo "    Image tag deployed : $IMAGE_TAG"
echo "    ECS cluster        : $(terraform -chdir="$INFRA_DIR" output -raw ecs_cluster_name)"
echo "    ECS service        : $(terraform -chdir="$INFRA_DIR" output -raw ecs_service_name)"
echo "    API endpoint        : $(terraform -chdir="$INFRA_DIR" output -raw api_endpoint)"
