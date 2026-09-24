# TODO: vpc_id, public_subnet_ids, ecs security group id

variable "vpc_id" {
  description = "VPC ID."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets to place the ALB in."
  type        = list(string)
}

variable "project_name" {
  description = "Short project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)."
  type        = string
}

variable "container_port" {
  description = "Port the ECS app container listens on; used as the target group port."
  type        = number
  default     = 8080
}

variable "health_check_path" {
  description = "Path the target group health check hits."
  type        = string
  default     = "/health"
}
