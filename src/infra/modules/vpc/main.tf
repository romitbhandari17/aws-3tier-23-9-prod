# Isolated application VPC. There is deliberately no internet gateway, NAT
# gateway, or default route; AWS service access is provided only by endpoints.

# Used to auto-pick 2 AZs when var.availability_zones isn't explicitly set.
data "aws_availability_zones" "available" {
  state = "available"
}

# Region/account/partition lookups below are only used to build the fully
# qualified ARNs for this app's ECR repo, log group, and secret — so the
# endpoint IAM policies further down can scope access to just those
# resources instead of allowing account-wide access.
data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  # Exactly 2 AZs: one private subnet + one interface endpoint per AZ used.
  # Falls back to the first 2 AZs available in the region if the caller
  # doesn't pin specific ones via var.availability_zones.
  azs = length(var.availability_zones) == 2 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 2)

  # These ARNs must exactly match the resource names created by the ecs
  # module (aws_ecr_repository.app, aws_cloudwatch_log_group.app) and the
  # rds module (aws_secretsmanager_secret.db) — they're built here, ahead of
  # those resources existing, purely from naming convention, so the endpoint
  # policies below can be scoped without introducing a module dependency
  # cycle (endpoints are created before ecs/rds in the root module's graph).
  ecr_repository_arn = "arn:${data.aws_partition.current.partition}:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/${var.project_name}-${var.environment}-app"
  log_group_arn      = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}-${var.environment}-app:*"
  # Secrets Manager appends a random 6-character suffix to the secret name,
  # so the ARN can't be pinned exactly ahead of creation — the trailing `-*`
  # wildcard matches only that suffix, not other secrets.
  secret_arn = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}-${var.environment}-db-credentials-*"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for interface endpoint private DNS to resolve

  tags = {
    Name        = "${var.project_name}-${var.environment}-vpc"
    Environment = var.environment
  }
}

# One private subnet per AZ used (2 total). No public subnets exist in this
# VPC — there is nothing for ECS tasks to reach the internet through.
resource "aws_subnet" "private" {
  for_each                = { for index, az in local.azs : az => index }
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, each.value)
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.project_name}-${var.environment}-private-${each.key}"
    Tier        = "private"
    Environment = var.environment
  }
}

# Single route table shared by both private subnets. Deliberately has no
# 0.0.0.0/0 route to an internet gateway or NAT gateway — the only route it
# ever gets is the S3 prefix-list route that AWS adds automatically when the
# S3 gateway endpoint below is associated with it. That means there is no
# path out of this VPC to the public internet at all.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = "${var.project_name}-${var.environment}-private"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ECS tasks' security group. Created here (not in the ecs module) so the
# endpoints security group below can allow inbound HTTPS from it by ID
# without the vpc and ecs modules needing to depend on each other (the ecs
# module attaches its own ingress rules to this SG's id — see
# modules/ecs/main.tf).
resource "aws_security_group" "ecs_tasks" {
  name_prefix = "${var.project_name}-${var.environment}-ecs-"
  description = "ECS tasks; ingress is added by the ECS module"
  vpc_id      = aws_vpc.this.id

  # Egress restricted to the VPC CIDR only (talks to the ALB, RDS, and the
  # interface endpoints' ENIs — all inside this VPC). No 0.0.0.0/0 egress:
  # there's no internet route for it to use even if allowed.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  # S3 Gateway Endpoint traffic (ECR image layer blobs) is still addressed
  # to S3's real public IP ranges even though the route table sends it
  # privately over the endpoint — security groups filter on destination IP,
  # not on which route was used, so the VPC-CIDR-only rule above silently
  # drops it. This rule scopes egress to just the S3 prefix list (not
  # 0.0.0.0/0) so it still can't reach the actual internet.
  egress {
    description     = "HTTPS to S3 (ECR image layers) via the S3 gateway endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id]
  }
}

# Security group attached to every interface endpoint's ENIs. Endpoints are
# reached over HTTPS, so only 443 needs to be open, and only from the ECS
# task security group — nothing else in (or outside) the VPC can use them.
resource "aws_security_group" "endpoints" {
  name_prefix = "${var.project_name}-${var.environment}-endpoints-"
  description = "VPC interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTPS from ECS tasks"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }
}

# Endpoint policies below scope each interface endpoint down to only the
# ARN this app actually needs, instead of the default "allow all principals,
# all actions, all resources" endpoint policy. Each is attached to its
# matching aws_vpc_endpoint via the `policy` argument further down.

# ecr.api handles auth/metadata calls (e.g. GetAuthorizationToken) made
# before the image layer pull itself; ecr.dkr (below) handles the pull.
data "aws_iam_policy_document" "ecr_api" {
  statement {
    # GetAuthorizationToken is an account-level, non-resource action — AWS
    # requires it to be called with resources = ["*"]; it cannot be scoped
    # to a single repository ARN.
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]

    # VPC endpoint policies are resource-based policies, like S3 bucket
    # policies — AWS rejects the whole document with a generic
    # InvalidPolicyDocument error if any statement omits a Principal.
    # Actual access is still restricted by actions/resources above and by
    # the endpoint's security group, not by who the principal is.
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer"
    ]
    resources = [local.ecr_repository_arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

# ecr.dkr is the endpoint the Docker/OCI image pull protocol itself talks
# to (layer manifests + blobs) once ecr.api has authorized the caller.
data "aws_iam_policy_document" "ecr_dkr" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer"
    ]
    resources = [local.ecr_repository_arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

# Scopes the logs endpoint to only this app's log group — the ECS execution
# role uses this endpoint to ship container stdout/stderr to CloudWatch.
data "aws_iam_policy_document" "logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]
    resources = [local.log_group_arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

# Scopes the secretsmanager endpoint to only this app's DB credentials
# secret — used by the ECS task execution role to resolve the `secrets`
# block in the task definition (DB_HOST/DB_USER/DB_PASSWORD/etc.) at
# container start.
data "aws_iam_policy_document" "secretsmanager" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.secret_arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

# One interface endpoint per AWS service this app needs, one ENI per AZ
# (placed in both private subnets), each locked down by the endpoints SG
# above and its own scoped policy from the data sources above.
resource "aws_vpc_endpoint" "interface" {
  for_each = {
    ecr_api        = { service = "ecr.api", policy = data.aws_iam_policy_document.ecr_api.json }
    ecr_dkr        = { service = "ecr.dkr", policy = data.aws_iam_policy_document.ecr_dkr.json }
    logs           = { service = "logs", policy = data.aws_iam_policy_document.logs.json }
    secretsmanager = { service = "secretsmanager", policy = data.aws_iam_policy_document.secretsmanager.json }
  }

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value.service}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true # lets the app/ECS agent resolve the standard AWS SDK endpoint hostnames privately, no code changes needed
  subnet_ids          = [for subnet in aws_subnet.private : subnet.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  policy              = each.value.policy

  tags = {
    Name        = "${var.project_name}-${var.environment}-${each.key}"
    Environment = var.environment
  }
}

# Gateway endpoint (no hourly/interface cost) for S3. Required alongside the
# ecr.dkr interface endpoint above: ECR stores actual image layer blobs in
# S3, so image pulls still route to S3 even when the ECR API/registry calls
# go through the ecr.api/ecr.dkr interface endpoints. Without this, image
# pulls fail from a private-subnet task with no internet route.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id] # AWS auto-adds the S3 prefix-list route to this table

  tags = {
    Name        = "${var.project_name}-${var.environment}-s3"
    Environment = var.environment
  }
}
