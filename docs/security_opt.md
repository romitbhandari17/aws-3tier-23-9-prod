# Actual Changes: Network Isolation for ECS

This document lists the concrete Terraform changes made to implement network
isolation for the ECS Fargate service: private subnets with no internet
route, VPC endpoints instead of a NAT Gateway, endpoint-scoped IAM/endpoint
policies, and security-group-restricted access to the interface endpoints.

All state files (`terraform.tfstate`, `terraform.tfstate.backup`,
`.terraform/`, `.terraform.lock.hcl`) were deleted from `src/infra/` before
this work — they were untracked/gitignored artifacts, not committed history,
so removing them has no git impact. A fresh `terraform init && terraform
plan` is required before the next `apply`.

---

## 1. `src/infra/modules/vpc/main.tf` (new content, previously a 2-line placeholder)

Built out the entire isolated VPC:

- **Lines 1–2**: Header comment — no internet gateway, NAT gateway, or
  default route; AWS access only via endpoints.
- **Lines 4–17**: `data "aws_availability_zones" "available"`,
  `data "aws_region" "current"`, `data "aws_caller_identity" "current"`,
  `data "aws_partition" "current"`, and a `locals` block computing:
  - `azs` — exactly 2 AZs (from `var.availability_zones` or the first 2
    available in the region).
  - `ecr_repository_arn`, `log_group_arn`, `secret_arn` — scoped ARNs for
    this app's ECR repo, CloudWatch log group, and Secrets Manager secret,
    used to lock down endpoint policies (see below).
- **Lines 21–29**: `aws_vpc.this` — the isolated VPC (`var.vpc_cidr`,
  default `10.42.0.0/16`), DNS support/hostnames enabled.
- **Lines 31–43**: `aws_subnet.private` (`for_each` over the 2 AZs) — private
  subnets only, `map_public_ip_on_launch = false`.
- **Lines 45–56**: `aws_route_table.private` + `aws_route_table_association.private`
  — a route table with **no internet/NAT route** (only the S3 gateway
  endpoint route is added later, automatically, by AWS).
- **Lines 58–70**: `aws_security_group.ecs_tasks` — the ECS task security
  group, created here (not in the ecs module) so the endpoint SG below can
  reference it without a module dependency cycle. Egress restricted to the
  VPC CIDR only (no `0.0.0.0/0` egress — tasks have nowhere to route to
  outside the VPC).
- **Lines 72–83**: `aws_security_group.endpoints` — SG for the 4 interface
  endpoints; **ingress: HTTPS (443) from `aws_security_group.ecs_tasks` only**.
- **Lines 85–137**: Four `data "aws_iam_policy_document"` blocks
  (`ecr_api`, `ecr_dkr`, `logs`, `secretsmanager`) — each scoped to only
  this app's ECR repo ARN / log group ARN / secret ARN (not account-wide).
  `ecr:GetAuthorizationToken` is left as `resources = ["*"]` because AWS
  requires that specific action to be unscoped.
- **Lines 139–160**: `aws_vpc_endpoint.interface` (`for_each` over
  `ecr_api`, `ecr_dkr`, `logs`, `secretsmanager`) — one interface endpoint
  per service, `private_dns_enabled = true`, placed in both private subnets
  (one per AZ used), attached to the endpoints SG, with the matching scoped
  policy attached via `policy = each.value.policy`.
- **Lines 162–172**: `aws_vpc_endpoint.s3` — the **S3 gateway endpoint**
  (no hourly cost), attached to the private route table; required because
  ECR stores image layers in S3.

## 2. `src/infra/modules/vpc/variables.tf` (previously a 1-line placeholder)

- Added `project_name`, `environment` (used for naming).
- Added `vpc_cidr` (default `10.42.0.0/16`).
- Added `availability_zones` (default `[]` = auto-pick 2) with a validation
  block requiring exactly 0 or 2 entries.

## 3. `src/infra/modules/vpc/outputs.tf` (previously a 1-line placeholder)

- `vpc_id` (line 1–3)
- `private_subnet_ids` (line 5–7)
- `ecs_security_group_id` (line 9–12) — new output exposing the ECS task SG
  so the ecs module can attach ingress rules to it and the ECS service can
  use it directly.

## 4. `src/infra/modules/ecs/main.tf`

- **Removed** (previously lines 6–24): `resource "aws_security_group" "this"`
  — the inline ECS SG definition with `egress { cidr_blocks = ["0.0.0.0/0"] }`
  and its ALB ingress rule. The SG now lives in the vpc module instead
  (see item 1) so its egress can be restricted and the endpoint SG can
  reference it.
- **Added** (new lines 7–24): `aws_security_group_rule.alb_to_ecs` (ingress,
  `var.container_port`, source = `var.alb_security_group_id`, target =
  `var.ecs_security_group_id`) and `aws_security_group_rule.ecs_to_rds`
  (ingress, `var.db_port`, source = `var.ecs_security_group_id`, target =
  `var.rds_security_group_id`) — both now attach to the VPC-module-owned SG
  by ID instead of creating/depending on a locally-owned SG resource.
- **Line ~95** (`aws_ecs_service.app.network_configuration`):
  - `security_groups = [aws_security_group.this.id]` → `security_groups = [var.ecs_security_group_id]`
  - `assign_public_ip = true # no NAT Gateway in this demo; tasks need a public IP to pull from ECR`
    → **`assign_public_ip = false`**

## 5. `src/infra/modules/ecs/variables.tf`

- **Added** (lines 8–11): `variable "ecs_security_group_id"` — the SG ID
  created by the vpc module, now required input instead of the module
  creating its own SG.

## 6. `src/infra/modules/ecs/outputs.tf`

- **`security_group_id` output** (was `value = aws_security_group.this.id`)
  → **`value = var.ecs_security_group_id`** — output now passes through the
  vpc-module-owned SG id instead of a locally created resource.

## 7. `src/infra/main.tf`

- **Added** `module "vpc"` block (new, ~lines 20–25) — instantiates the new
  VPC module first; every other module now depends on its outputs.
- **Removed** `data "aws_vpc" "default"` and `data "aws_subnets" "default"`
  (previously looked up the account's default VPC/subnets).
- **`module "rds"`**: `vpc_id`/`subnet_ids` now come from
  `module.vpc.vpc_id` / `module.vpc.private_subnet_ids` instead of
  `data.aws_vpc.default` / `data.aws_subnets.default`.
- **`module "alb"`**: same substitution — ALB (already internal-only) now
  sits in the private subnets.
- **`module "ecs"`**: same substitution, **plus** new argument
  `ecs_security_group_id = module.vpc.ecs_security_group_id`; `depends_on`
  extended to include `module.vpc`.
- **`module "apigateway"`**: same `vpc_id`/`subnet_ids` substitution (its
  VPC Link ENIs now also sit in the private, no-internet-route subnets).
- Updated the header comment block to describe the private-VPC/endpoint
  design instead of the "default VPC, demo simplification" note.

---

## Summary of security posture change

| Aspect | Before | After |
|---|---|---|
| ECS task subnets | Account default VPC (public-routable) subnets | Purpose-built private subnets, no IGW/NAT |
| ECS task public IP | `assign_public_ip = true` | `assign_public_ip = false` |
| ECS task egress | `0.0.0.0/0` (all protocols) | VPC CIDR only |
| Path to ECR/Logs/Secrets Manager | Public internet via task's public IP | Interface VPC endpoints (ecr.api, ecr.dkr, logs, secretsmanager) |
| Path to S3 (ECR image layers) | Public internet | S3 gateway endpoint on the private route table |
| Endpoint access control | N/A | New SG: HTTPS (443) inbound from ECS task SG only |
| Endpoint IAM scope | N/A | Per-endpoint policy scoped to this app's ECR repo / log group / secret ARN |
| NAT Gateway | Not present (relied on public IPs instead) | Still not present — not needed; documented as a future fallback only if third-party internet egress is ever required |

## Not changed

- `src/infra/modules/rds/*`, `src/infra/modules/alb/*` (structure),
  `src/infra/modules/apigateway/*` — no code changes beyond receiving
  private subnet IDs from the root module; RDS and ALB already had
  `publicly_accessible = false` / `internal = true`.
- No NAT Gateway resource was added, per the requirement to prefer VPC
  endpoints and only add NAT if/when non-AWS internet egress is needed.
