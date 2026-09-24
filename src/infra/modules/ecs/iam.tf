# IAM roles required to run the ECS Fargate service.

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution role: used by the ECS agent (not the app) to pull the container
# image from ECR and ship logs to CloudWatch on the task's behalf.
resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${var.project_name}-${var.environment}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Optional: let the execution role read the DB secret so it can be injected
# into the container as an environment variable via task definition "secrets".
resource "aws_iam_role_policy" "ecs_task_execution_secrets" {
  count = var.enable_db_secret_access ? 1 : 0
  name  = "${var.project_name}-${var.environment}-ecs-secrets-read"
  role  = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.db_secret_arn
      }
    ]
  })
}

# Task role: assumed by the application code running inside the container
# (e.g. to call other AWS services). Left empty for this demo — attach
# additional inline/managed policies here as the app's real needs grow.
resource "aws_iam_role" "ecs_task_role" {
  name               = "${var.project_name}-${var.environment}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
}
