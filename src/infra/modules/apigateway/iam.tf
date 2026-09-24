# Account-level IAM role allowing API Gateway to push execution/access logs
# to CloudWatch Logs.
#
# NOTE: aws_api_gateway_account is an *account+region-wide* setting (there is
# only one per account/region). If multiple stacks/environments share this
# AWS account, only apply this resource from one of them to avoid conflicts.

data "aws_iam_policy_document" "apigateway_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigateway_cloudwatch_role" {
  name               = "${var.project_name}-${var.environment}-apigw-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.apigateway_assume_role.json
}

resource "aws_iam_role_policy_attachment" "apigateway_cloudwatch_role_policy" {
  role       = aws_iam_role.apigateway_cloudwatch_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigateway_cloudwatch_role.arn
}
