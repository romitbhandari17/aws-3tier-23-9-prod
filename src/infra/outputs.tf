output "api_endpoint" {
  description = "Public HTTP endpoint for the demo API (try GET {endpoint}/courses)."
  value       = module.apigateway.api_endpoint
}

output "ecr_repository_url" {
  description = "Push the app image here before running `terraform apply` a second time / forcing a new ECS deployment."
  value       = module.ecs.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name (used by scripts/deploy-ecs.sh and for manual `aws ecs` commands)."
  value       = module.ecs.cluster_name
}

output "ecs_service_name" {
  description = "ECS service name (used by scripts/deploy-ecs.sh and for manual `aws ecs` commands)."
  value       = module.ecs.service_name
}
