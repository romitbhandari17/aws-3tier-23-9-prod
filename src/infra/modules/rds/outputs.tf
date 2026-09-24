# TODO: expose db_endpoint, db_port

output "db_address" {
  description = "RDS instance hostname (no port)."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "Port the DB listens on."
  value       = var.db_port
}

output "db_name" {
  description = "Database name."
  value       = var.db_name
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret holding DB connection info."
  value       = aws_secretsmanager_secret.db.arn
}

output "security_group_id" {
  description = "Security group ID attached to the RDS instance (the ECS module adds the ingress rule permitting itself)."
  value       = aws_security_group.this.id
}

output "monitoring_role_arn" {
  description = "ARN of the RDS Enhanced Monitoring IAM role, if enabled (empty string otherwise)."
  value       = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring_role[0].arn : ""
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key used to encrypt RDS storage at rest."
  value       = aws_kms_key.rds.arn
}
