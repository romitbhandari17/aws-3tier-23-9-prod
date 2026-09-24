# TODO: expose api_endpoint

output "api_endpoint" {
  description = "Public invoke URL for the API (hits ANY /{proxy+})."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "cloudwatch_role_arn" {
  description = "ARN of the IAM role API Gateway uses to push logs to CloudWatch."
  value       = aws_iam_role.apigateway_cloudwatch_role.arn
}
