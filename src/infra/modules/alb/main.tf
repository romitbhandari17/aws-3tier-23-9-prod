# ALB module.
#
# Kept internal (not internet-facing): API Gateway is the only public entry
# point for this demo and reaches the ALB privately via a VPC Link.

# Security group owned by this module, with NO inline ingress rule — the
# apigateway module attaches the "allow HTTP from VPC Link" rule to this
# SG's id (via a security_group_rule resource) because apigateway already
# depends on this module's `listener_arn` output; having ALB depend back on
# apigateway's SG id would create a module cycle.
resource "aws_security_group" "this" {
  name_prefix = "${var.project_name}-${var.environment}-alb-"
  description = "ALB security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.this.id]
  subnets            = var.subnet_ids
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-${var.environment}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # required for Fargate awsvpc networking

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
