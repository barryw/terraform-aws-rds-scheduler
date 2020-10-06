terraform {
  required_version = ">= 0.12.0"
}

resource "aws_iam_role" "rds-scheduler" {
  name = "${var.identifier}-rds-scheduler"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

/* Find the RDS Cluster. We need its ARN */
data "aws_rds_cluster" "rds-cluster" {
  count = var.is_cluster ? 1 : 0
  cluster_identifier = var.rds_identifier
}

/* Find the RDS Instance. We need its ARN */
data "aws_db_instance" "rds-instance" {
  count = var.is_cluster ? 0 : 1
  db_instance_identifier = var.rds_identifier
}

data "aws_iam_policy_document" "rds-cluster" {
  count = var.is_cluster ? 1 : 0
  statement {
    actions = [
      "rds:DescribeDBClusters",
      "rds:StartDBCluster",
      "rds:StopDBCluster"
    ]
    resources = [
      data.aws_rds_cluster.rds-cluster.0.arn
    ]
  }
}

data "aws_iam_policy_document" "rds-instance" {
  count = var.is_cluster ? 0 : 1
  statement {
    actions = [
      "rds:DescribeDBInstances",
      "rds:StartDBInstance",
      "rds:StopDBInstance"
    ]
    resources = [
      data.aws_db_instance.rds-instance.0.db_instance_arn
    ]
  }
}

/* Add a couple of managed policies to allow Lambda to write to CloudWatch & XRay */
resource "aws_iam_role_policy_attachment" "lambda-basic-execution" {
  role = aws_iam_role.rds-scheduler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda-xray" {
  role = aws_iam_role.rds-scheduler.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

resource "aws_iam_policy" "rds-cluster" {
  count = var.is_cluster ? 1 : 0
  name = "${var.identifier}-rds-scheduler-rds-cluster"
  path = "/"
  policy = data.aws_iam_policy_document.rds-cluster.0.json
}

resource "aws_iam_policy" "rds-instance" {
  count = var.is_cluster ? 0 : 1
  name = "${var.identifier}-rds-scheduler-rds-instance"
  path = "/"
  policy = data.aws_iam_policy_document.rds-instance.0.json
}

resource "aws_iam_role_policy_attachment" "rds-cluster" {
  count      = var.is_cluster ? 1 : 0
  role       = aws_iam_role.rds-scheduler.name
  policy_arn = aws_iam_policy.rds-cluster.0.arn
}

resource "aws_iam_role_policy_attachment" "rds-instance" {
  count      = var.is_cluster ? 0 : 1
  role       = aws_iam_role.rds-scheduler.name
  policy_arn = aws_iam_policy.rds-instance.0.arn
}

/* Create a zip file containing the lambda code */
data "archive_file" "rds-scheduler" {
  type        = "zip"
  source_dir = "${path.module}/package"
  output_path = "${path.module}/rds-scheduler.zip"
}

/* The lambda resource */
resource "aws_lambda_function" "rds-scheduler" {
  filename = data.archive_file.rds-scheduler.output_path
  function_name = "${var.identifier}-rds-scheduler"
  description = "Start and stop an RDS cluster/instance on a schedule"
  role = aws_iam_role.rds-scheduler.arn
  handler = "rds_scheduler.lambda_handler"
  runtime = "python3.7"
  timeout = 300
  source_code_hash = data.archive_file.rds-scheduler.output_base64sha256

  environment {
    variables = {
      RDS_IDENTIFIER  = var.rds_identifier
      IS_CLUSTER      = var.is_cluster
      SKIP_EXECUTION  = var.skip_execution
      START_EVENT_ARN = aws_cloudwatch_event_rule.up-schedule.arn
      STOP_EVENT_ARN  = aws_cloudwatch_event_rule.down-schedule.arn
    }
  }
}

resource "aws_lambda_permission" "up-schedule" {
  statement_id = "AllowUpScheduleExecutionFromCloudWatch"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds-scheduler.function_name
  principal = "events.amazonaws.com"
  source_arn = aws_cloudwatch_event_rule.up-schedule.arn
}

resource "aws_lambda_permission" "down-schedule" {
  statement_id = "AllowDownScheduleExecutionFromCloudWatch"
  action = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds-scheduler.function_name
  principal = "events.amazonaws.com"
  source_arn = aws_cloudwatch_event_rule.down-schedule.arn
}

/* CloudWatch event rule and target for the 'up' schedule */
resource "aws_cloudwatch_event_rule" "up-schedule" {
  name = "${var.identifier}-up-schedule"
  description = "The 'up' schedule for ${var.identifier}"
  schedule_expression = "cron(${var.up_schedule})"
}

resource "aws_cloudwatch_event_target" "up-schedule-target" {
  target_id = "${var.identifier}-up-schedule"
  rule = aws_cloudwatch_event_rule.up-schedule.name
  arn = aws_lambda_function.rds-scheduler.arn
}

/* CloudWatch event rule and target for the 'down' schedule */
resource "aws_cloudwatch_event_rule" "down-schedule" {
  name = "${var.identifier}-down-schedule"
  description = "The 'down' schedule for ${var.identifier}"
  schedule_expression = "cron(${var.down_schedule})"
}

resource "aws_cloudwatch_event_target" "down-schedule-target" {
  target_id = "${var.identifier}-down-schedule"
  rule = aws_cloudwatch_event_rule.down-schedule.name
  arn = aws_lambda_function.rds-scheduler.arn
}
