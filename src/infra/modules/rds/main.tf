# RDS module: single Postgres instance for the demo "courses" table.
# Schema creation + hardcoded seed data is handled by the app on startup
# (see src/ecs/app/app.py) — kept minimal on purpose for this demo.

# Ask AWS for the latest available Postgres 16.x minor version instead of
# hardcoding one that may eventually be deprecated.
data "aws_rds_engine_version" "postgres" {
  engine             = "postgres"
  preferred_versions = ["16.4", "16.3", "16.2", "16.1"]
}

# Not every AZ in a region/account supports every engine+instance_class
# combination (e.g. "Subnet '...' is in Availability Zone '...' where
# service is not available"). AZ *names* (us-east-1a, ...) map to different
# physical AZs per AWS account, so we can't just hardcode which one to
# skip — instead ask RDS which AZs actually support this instance class,
# then filter the incoming subnets down to only those AZs.
data "aws_rds_orderable_db_instance" "postgres" {
  engine         = "postgres"
  engine_version = data.aws_rds_engine_version.postgres.version
  instance_class = var.instance_class
  storage_type   = "gp2"
  license_model  = "postgresql-license"
}

data "aws_subnet" "candidates" {
  # Keyed by list index, not by subnet ID itself: the subnet IDs aren't
  # known until the vpc module's subnets are created on first apply, and
  # toset() over unknown values makes for_each unable to determine its keys
  # ahead of time ("for_each set includes values derived from resource
  # attributes"). Indexes are static, so this works even though the values
  # (the IDs) are computed.
  for_each = { for idx, id in var.subnet_ids : idx => id }
  id       = each.value
}

locals {
  # Subnets whose AZ is confirmed orderable for this instance class.
  rds_subnet_ids = [
    for s in data.aws_subnet.candidates : s.id
    if contains(data.aws_rds_orderable_db_instance.postgres.availability_zones, s.availability_zone)
  ]
}

# Security group owned by this module. It has NO inline ingress rule here —
# the ECS module attaches the "allow Postgres from ECS" rule to this SG's id
# (via a security_group_rule resource) because ECS already depends on this
# module's `secret_arn` output; having RDS depend back on ECS's SG id would
# create a module cycle. See modules/ecs/main.tf for that rule.
resource "aws_security_group" "this" {
  name_prefix = "${var.project_name}-${var.environment}-rds-"
  description = "RDS instance security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.project_name}-${var.environment}-db-subnets"
  subnet_ids = local.rds_subnet_ids

  lifecycle {
    precondition {
      condition     = length(local.rds_subnet_ids) >= 2
      error_message = "Fewer than 2 of the given subnets are in an AZ that supports RDS instance class '${var.instance_class}' for postgres ${data.aws_rds_engine_version.postgres.version}. A DB subnet group needs subnets in at least 2 AZs — pass more subnet_ids or a different instance_class."
    }
  }
}

resource "aws_db_instance" "this" {
  identifier             = "${var.project_name}-${var.environment}-db"
  engine                 = "postgres"
  engine_version         = data.aws_rds_engine_version.postgres.version
  instance_class         = var.instance_class
  storage_type           = "gp2" # kept in sync with the aws_rds_orderable_db_instance query above
  allocated_storage      = var.allocated_storage
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  port                   = var.db_port
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  publicly_accessible     = false
  multi_az                = false
  skip_final_snapshot     = true
  apply_immediately       = true
  backup_retention_period = 0

  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring_role[0].arn : null

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Store full connection info so ECS can pull it in as container secrets.
resource "aws_secretsmanager_secret" "db" {
  name = "${var.project_name}-${var.environment}-db-credentials"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    host     = aws_db_instance.this.address
    port     = var.db_port
    dbname   = var.db_name
  })
}
