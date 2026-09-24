variable "vpc_id" {
  description = "VPC ID the DB subnet group is created in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the DB subnet group."
  type        = list(string)
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
  description = "Master password for the database (passed in from root; not generated here)."
  type        = string
  sensitive   = true
}

variable "db_port" {
  description = "Port Postgres listens on."
  type        = number
  default     = 5432
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB."
  type        = number
  default     = 20
}

variable "project_name" {
  description = "Short project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)."
  type        = string
}

variable "monitoring_interval" {
  description = "RDS Enhanced Monitoring interval in seconds (0 disables enhanced monitoring and skips creating the monitoring IAM role)."
  type        = number
  default     = 0
}
