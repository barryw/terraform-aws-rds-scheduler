output "scheduler_role_arn" {
  value = "${aws_iam_role.rds-scheduler.arn}"
  description = "The arn of the role created for the start/stop Lambda"
}

output "scheduler_lambda_arn" {
  value = "${aws_lambda_function.rds-scheduler.arn}"
  description = "The arn of the start/stop Lambda function"
}

output "down_schedule_target_arn" {
  value = "${aws_cloudwatch_event_target.down-schedule-target.arn}"
  description = "The arn of the down schedule target"
}

output "up_schedule_target_arn" {
  value = "${aws_cloudwatch_event_target.up-schedule-target.arn}"
  description = "The arn of the up schedule target"
}

output "down_schedule_rule_arn" {
  value = "${aws_cloudwatch_event_rule.down-schedule.arn}"
  description = "The arn of the down schedule rule"
}

output "up_schedule_rule_arn" {
  value = "${aws_cloudwatch_event_rule.up-schedule.arn}"
  description = "The arn of the up schedule rule"
}
