output "lambda_arn" {
  value = module.scheduler.scheduler_lambda_arn
}

output "stop_rule_arn" {
  value = module.scheduler.down_schedule_rule_arn
}

output "start_rule_arn" {
  value = module.scheduler.up_schedule_rule_arn
}

output "rds_identifier" {
  value = aws_db_instance.test.identifier
}
