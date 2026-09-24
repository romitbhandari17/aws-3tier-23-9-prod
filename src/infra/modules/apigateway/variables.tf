# TODO: alb_listener_arn or alb_arn, vpc_id, private_subnet_ids

variable "alb_listener_arn" {
  description = "ARN of the ALB HTTP listener to integrate with privately."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets used for the API Gateway VPC Link ENIs."
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID (used only to create this module's own VPC Link security group)."
  type        = string
}

variable "alb_security_group_id" {
  description = "ALB's security group ID; this module grants it inbound access from the VPC Link security group it creates."
  type        = string
}

variable "project_name" {
  description = "Short project name used for resource naming."
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)."
  type        = string
}

variable "excluded_availability_zone_ids" {
  description = "AZ IDs to exclude from VPC Link subnet placement (default excludes use1-az3, where NLB/VPC Link capacity is commonly unavailable in us-east-1 accounts). AZ IDs are consistent across accounts, unlike AZ names."
  type        = list(string)
  default     = ["use1-az3"]
}
