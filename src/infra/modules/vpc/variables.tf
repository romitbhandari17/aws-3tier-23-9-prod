variable "project_name" {
  description = "Short project name used for resource naming (matches every other module's naming convention)."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod); combined with project_name as the naming prefix."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the isolated application VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "availability_zones" {
  description = "Exactly two AZ names used for private subnets and interface endpoints. Empty selects the first two available AZs."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 2
    error_message = "availability_zones must be empty or contain exactly two AZ names."
  }
}
