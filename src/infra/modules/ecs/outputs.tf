# TODO: expose ecs_cluster_name, ecs_service_name

output "ecr_repository_url" {
  description = "ECR repository URL to push the app image to."
  value       = aws_ecr_repository.app.repository_url
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.app.name
}

output "security_group_id" {
  description = "Security group ID attached to ECS tasks."
  value       = var.ecs_security_group_id
}

output "task_execution_role_arn" {
  description = "ARN of the ECS task execution role (pulls image, writes logs, reads secrets)."
  value       = aws_iam_role.ecs_task_execution_role.arn
}

output "task_role_arn" {
  description = "ARN of the ECS task role assumed by the application container."
  value       = aws_iam_role.ecs_task_role.arn
}
