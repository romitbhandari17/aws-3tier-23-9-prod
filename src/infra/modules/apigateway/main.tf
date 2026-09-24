# API Gateway (HTTP API) module: the only public entry point for this demo.
# Reaches the internal ALB privately through a VPC Link.

# aws_apigatewayv2_vpc_link provisions a Network Load Balancer-backed
# connection under the hood, and NLB capacity has long been unavailable in
# AZ ID "use1-az3" for many AWS accounts in us-east-1 (a well-known,
# long-standing AWS capacity quirk — see "BadRequestException: Subnet '...'
# is in Availability Zone '...' where service is not available"). AZ *IDs*
# (use1-az1, use1-az2, use1-az3, ...) are consistent across every AWS
# account in a region, unlike AZ *names* (us-east-1a, ...) which are
# shuffled per account — so filtering by AZ ID here is safe to hardcode,
# unlike the AZ names themselves. See variables.tf for
# excluded_availability_zone_ids.
data "aws_subnet" "candidates" {
  # Keyed by list index, not by subnet ID itself: the subnet IDs aren't
  # known until the vpc module's subnets are created on first apply, and
  # toset() over unknown values makes for_each unable to determine its keys
  # ahead of time ("for_each set includes values derived from resource
  # attributes"). Indexes are static, so this works even though the values
  # (the IDs) are computed.
  for_each = { for idx, id in var.subnet_ids : idx => id }
  id       = each.value
}

locals {
  vpc_link_subnet_ids = [
    for s in data.aws_subnet.candidates : s.id
    if !contains(var.excluded_availability_zone_ids, s.availability_zone_id)
  ]
}

# Security group for the VPC Link's ENIs. Egress-only — it's the source of
# traffic, not a destination, so no inbound rule is needed here.
resource "aws_security_group" "vpc_link" {
  name_prefix = "${var.project_name}-${var.environment}-vpclink-"
  description = "API Gateway VPC Link ENIs"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Grants the VPC Link access into the ALB. Lives here (not in the alb
# module) because apigateway already depends on the ALB's `listener_arn`
# output; having ALB depend back on this module's SG id would create a
# module cycle. This resource just attaches a rule to the ALB SG from here.
resource "aws_security_group_rule" "vpc_link_to_alb" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = var.alb_security_group_id
  source_security_group_id = aws_security_group.vpc_link.id
  description              = "HTTP from API Gateway VPC Link"
}

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.project_name}-${var.environment}-vpclink"
  subnet_ids         = local.vpc_link_subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]

  lifecycle {
    precondition {
      condition     = length(local.vpc_link_subnet_ids) >= 2
      error_message = "Fewer than 2 of the given subnets remain after excluding AZ IDs ${jsonencode(var.excluded_availability_zone_ids)}. A VPC Link needs subnets in at least 2 AZs — pass more subnet_ids or adjust excluded_availability_zone_ids."
    }
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project_name}-${var.environment}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "alb" {
  api_id             = aws_apigatewayv2_api.this.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = var.alb_listener_arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.this.id
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.alb.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}
