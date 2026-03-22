data "aws_rds_cluster" "rds-cluster" {
  count              = var.is_cluster ? 1 : 0
  cluster_identifier = var.rds_identifier
}

data "aws_db_instance" "rds-instance" {
  count                  = var.is_cluster ? 0 : 1
  db_instance_identifier = var.rds_identifier
}

data "archive_file" "rds-scheduler" {
  type        = "zip"
  source_dir  = "${path.module}/package"
  output_path = "${path.module}/rds-scheduler.zip"
}

resource "aws_lambda_function" "rds-scheduler" {
  filename         = data.archive_file.rds-scheduler.output_path
  function_name    = "${var.identifier}-rds-scheduler"
  description      = "Start and stop an RDS cluster/instance on a schedule"
  role             = aws_iam_role.rds-scheduler.arn
  handler          = "rds_scheduler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  timeout          = 300
  source_code_hash = data.archive_file.rds-scheduler.output_base64sha256

  environment {
    variables = {
      RDS_IDENTIFIER  = var.rds_identifier
      IS_CLUSTER      = tostring(var.is_cluster)
      SKIP_EXECUTION  = tostring(var.skip_execution)
      START_EVENT_ARN = aws_cloudwatch_event_rule.up-schedule.arn
      STOP_EVENT_ARN  = aws_cloudwatch_event_rule.down-schedule.arn
    }
  }
}

resource "aws_lambda_permission" "up-schedule" {
  statement_id  = "AllowUpScheduleExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds-scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.up-schedule.arn
}

resource "aws_lambda_permission" "down-schedule" {
  statement_id  = "AllowDownScheduleExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds-scheduler.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.down-schedule.arn
}

resource "aws_cloudwatch_event_rule" "up-schedule" {
  name                = "${var.identifier}-up-schedule"
  description         = "The 'up' schedule for ${var.identifier}"
  schedule_expression = "cron(${var.up_schedule})"
}

resource "aws_cloudwatch_event_target" "up-schedule-target" {
  target_id = "${var.identifier}-up-schedule"
  rule      = aws_cloudwatch_event_rule.up-schedule.name
  arn       = aws_lambda_function.rds-scheduler.arn
}

resource "aws_cloudwatch_event_rule" "down-schedule" {
  name                = "${var.identifier}-down-schedule"
  description         = "The 'down' schedule for ${var.identifier}"
  schedule_expression = "cron(${var.down_schedule})"
}

resource "aws_cloudwatch_event_target" "down-schedule-target" {
  target_id = "${var.identifier}-down-schedule"
  rule      = aws_cloudwatch_event_rule.down-schedule.name
  arn       = aws_lambda_function.rds-scheduler.arn
}
