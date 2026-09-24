# ECS module: Fargate cluster/service running the demo Flask app that reads
# a hardcoded list of courses from RDS.

data "aws_region" "current" {}

# The ECS task security group itself is created in the vpc module (not here)
# so its egress can be restricted to the VPC CIDR and the endpoints security
# group can allow HTTPS from it by ID without a module dependency cycle. This
# module only attaches ingress rules to that SG's id, passed in as
# var.ecs_security_group_id.

# Only accepts app traffic from the ALB. The VPC module owns this SG because
# the endpoint SG must allow HTTPS from it.
resource "aws_security_group_rule" "alb_to_ecs" {
  type                     = "ingress"
  from_port                = var.container_port
  to_port                  = var.container_port
  protocol                 = "tcp"
  security_group_id        = var.ecs_security_group_id
  source_security_group_id = var.alb_security_group_id
  description              = "App traffic from ALB"
}

# Grants the ECS task SG access into RDS. Lives here (not in the rds module)
# because ECS already depends on RDS's `secret_arn` output — adding the
# reverse dependency (RDS -> ECS security group id) would create a module
# cycle. This resource just attaches a rule to the RDS SG from here.
resource "aws_security_group_rule" "ecs_to_rds" {
  type                     = "ingress"
  from_port                = var.db_port
  to_port                  = var.db_port
  protocol                 = "tcp"
  security_group_id        = var.rds_security_group_id
  source_security_group_id = var.ecs_security_group_id
  description              = "Postgres from ECS"
}

resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-${var.environment}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}-${var.environment}-app"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "this" {
  name = "${var.project_name}-${var.environment}-cluster"
}

resource "aws_ecs_task_definition" "app" {
  family                   = "${var.project_name}-${var.environment}-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]
      secrets = var.db_secret_arn != "" ? [
        { name = "DB_HOST", valueFrom = "${var.db_secret_arn}:host::" },
        { name = "DB_PORT", valueFrom = "${var.db_secret_arn}:port::" },
        { name = "DB_NAME", valueFrom = "${var.db_secret_arn}:dbname::" },
        { name = "DB_USER", valueFrom = "${var.db_secret_arn}:username::" },
        { name = "DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
      ] : []
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "app"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "app" {
  name            = "${var.project_name}-${var.environment}-app"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.ecs_security_group_id]
    # No public IP and no internet route: the task reaches ECR, CloudWatch
    # Logs, and Secrets Manager only through the VPC endpoints created in
    # the vpc module.
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "app"
    container_port   = var.container_port
  }
}
