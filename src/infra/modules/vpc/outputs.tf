output "vpc_id" {
  description = "ID of the isolated application VPC; passed to every other module instead of the account's default VPC."
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (one per AZ used, no internet route); every module's compute/database resources are placed here."
  value       = [for subnet in aws_subnet.private : subnet.id]
}

output "ecs_security_group_id" {
  description = "Security group ID used by ECS tasks and allowed to reach interface endpoints."
  value       = aws_security_group.ecs_tasks.id
}
