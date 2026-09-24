variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short project name; used as the naming prefix for every resource across all modules."
  type        = string
  default     = "coursesapp"
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod); combined with project_name as the naming prefix."
  type        = string
  default     = "dev"
}

variable "container_port" {
  description = "Port the app container listens on."
  type        = number
  default     = 8080
}

variable "image_tag" {
  description = "Container image tag to deploy (e.g. a git short SHA). Changing this forces a new ECS task definition revision and rolling deployment via `terraform apply` — see scripts/deploy-ecs.sh."
  type        = string
  default     = "latest"
}

variable "db_port" {
  description = "Port Postgres listens on."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "coursesdb"
}

variable "db_username" {
  description = "Master username for the database."
  type        = string
  default     = "appuser"
}

variable "db_password" {
  description = "Master password for the database. Supply via dev.tfvars (gitignored) or TF_VAR_db_password — do not commit real values."
  type        = string
  sensitive   = true
}
