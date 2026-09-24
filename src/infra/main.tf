# Root module: wires the shared modules together for the "dev" environment.
#
# Network isolation: every module below runs in the private, no-internet-route
# VPC built by modules/vpc (private subnets only, no NAT/IGW). AWS-managed
# dependencies (ECR, CloudWatch Logs, Secrets Manager, S3-backed ECR layers)
# are reached via VPC endpoints created in that module instead of a NAT
# Gateway — see docs/actual_changes.md for the full rationale and diff.
#
# Each module owns and creates its own security group (except the ECS task
# security group, which the vpc module owns so the endpoint security group
# can allow HTTPS from it without a module cycle). Cross-module ingress rules
# (e.g. "let ECS talk to RDS") are attached from whichever module already has
# a one-way dependency on the other, to avoid module cycles — see the
# comments inside modules/ecs/main.tf and modules/apigateway/main.tf.

# --- Modules ---
# project_name + environment are passed to every module; each module builds
# its own "${project_name}-${environment}-<resource>" naming prefix.

# VPC has no dependency on any other module; every other module depends on it.
module "vpc" {
  source = "./modules/vpc"

  project_name = var.project_name
  environment  = var.environment
}

# RDS depends only on the VPC (subnets + vpc_id).
module "rds" {
  source = "./modules/rds"

  project_name = var.project_name
  environment  = var.environment
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
  db_port      = var.db_port
  db_name      = var.db_name
  db_username  = var.db_username
  db_password  = var.db_password
}

# ALB depends only on the VPC (subnets + vpc_id).
module "alb" {
  source = "./modules/alb"

  project_name   = var.project_name
  environment    = var.environment
  vpc_id         = module.vpc.vpc_id
  subnet_ids     = module.vpc.private_subnet_ids
  container_port = var.container_port
}

# ECS depends on the VPC (task SG + subnets), RDS (secret + SG id), and ALB
# (target group + SG id).
module "ecs" {
  source = "./modules/ecs"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnet_ids
  ecs_security_group_id = module.vpc.ecs_security_group_id
  container_port        = var.container_port
  target_group_arn      = module.alb.target_group_arn
  alb_security_group_id = module.alb.security_group_id
  db_secret_arn         = module.rds.secret_arn
  rds_security_group_id = module.rds.security_group_id
  db_port               = var.db_port
  image_tag             = var.image_tag
  depends_on = [
    module.vpc,
    module.rds,
    module.alb
  ]
}

# apigateway depends on the VPC (subnets + vpc_id) and ALB (listener + SG id).
module "apigateway" {
  source = "./modules/apigateway"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  subnet_ids            = module.vpc.private_subnet_ids
  alb_listener_arn      = module.alb.listener_arn
  alb_security_group_id = module.alb.security_group_id
  depends_on = [
    module.alb
  ]
}
