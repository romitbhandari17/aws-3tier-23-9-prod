# TODO: vpc_id, private_subnet_ids, target_group_arn, container_image, container_port

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "ecs_security_group_id" {
  description = "Security group ID created by the vpc module and attached to ECS tasks; this module attaches its ALB/RDS ingress rules to this ID instead of creating its own SG (see main.tf for why)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets the ECS service's tasks run in."
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ALB's security group ID; ECS tasks accept inbound app traffic only from here."
  type        = string
}

variable "rds_security_group_id" {
  description = "RDS instance's security group ID; this module grants it inbound access from the ECS security group it creates."
  type        = string
}

variable "db_port" {
  description = "Port Postgres listens on (used only for the RDS ingress rule this module creates)."
  type        = number
  default     = 5432
}

variable "target_group_arn" {
  description = "ALB target group ARN the ECS service registers tasks with."
  type        = string
}

variable "container_port" {
  description = "Port the app container listens on."
  type        = number
  default     = 8080
}

variable "image_tag" {
  description = "Container image tag to deploy."
  type        = string
  default     = "latest"
}

variable "cpu" {
  description = "Fargate task vCPU units."
  type        = string
  default     = "256"
}

variable "memory" {
  description = "Fargate task memory (MiB)."
  type        = string
  default     = "512"
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks the Application Auto Scaling target will ever scale the service down to. Kept at 2+ so a rolling deploy or a single AZ failure never drops the service to zero healthy tasks."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks Application Auto Scaling can scale the service up to."
  type        = number
  default     = 4
}

variable "cpu_target_value" {
  description = "Target average CPU utilization (%) for the ECS service's CPU target-tracking auto scaling policy."
  type        = number
  default     = 70
}

variable "memory_target_value" {
  description = "Target average memory utilization (%) for the ECS service's memory target-tracking auto scaling policy."
  type        = number
  default     = 75
}

variable "project_name" {
  description = "Short project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the Secrets Manager secret holding DB credentials, if any. Leave empty to skip granting read access."
  type        = string
  default     = ""
}

variable "enable_db_secret_access" {
  description = "Whether to grant the execution role read access to db_secret_arn. Kept separate from db_secret_arn itself (rather than checking != \"\") because the secret's ARN contains an AWS-generated random suffix and is unknown until apply — using it directly in a `count` expression fails with 'value depends on resource attributes that cannot be determined until apply'."
  type        = bool
  default     = true
}
