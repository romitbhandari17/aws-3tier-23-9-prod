# TODO: expose alb_arn, alb_dns_name, target_group_arn

output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "target_group_arn" {
  value = aws_lb_target_group.app.arn
}

output "listener_arn" {
  value = aws_lb_listener.http.arn
}

output "security_group_id" {
  description = "Security group ID attached to the ALB (the apigateway module adds the ingress rule permitting the VPC Link)."
  value       = aws_security_group.this.id
}
