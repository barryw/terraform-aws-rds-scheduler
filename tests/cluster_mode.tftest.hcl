mock_provider "aws" {
  override_data {
    target = data.aws_iam_policy_document.lambda-assume-role
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.rds-cluster
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_rds_cluster.rds-cluster
    values = {
      arn = "arn:aws:rds:us-east-1:123456789012:cluster:my-aurora-cluster"
    }
  }
  override_resource {
    target = aws_iam_role.rds-scheduler
    values = {
      arn = "arn:aws:iam::123456789012:role/test-cluster-app-rds-scheduler"
    }
  }
  override_resource {
    target = aws_iam_policy.rds-cluster
    values = {
      arn = "arn:aws:iam::123456789012:policy/test-cluster-app-rds-scheduler-rds-cluster"
    }
  }
}
mock_provider "archive" {}

variables {
  identifier     = "test-cluster-app"
  rds_identifier = "my-aurora-cluster"
  is_cluster     = true
  up_schedule    = "50 10 ? * MON-FRI *"
  down_schedule  = "0 1 * * ? *"
}

run "cluster_mode_creates_correct_resources" {
  command = plan

  assert {
    condition     = aws_lambda_function.rds-scheduler.runtime == "python3.12"
    error_message = "Lambda runtime must be python3.12"
  }

  assert {
    condition     = contains(aws_lambda_function.rds-scheduler.architectures, "arm64")
    error_message = "Lambda must use arm64 architecture"
  }

  assert {
    condition     = aws_lambda_function.rds-scheduler.function_name == "test-cluster-app-rds-scheduler"
    error_message = "Lambda function name must include identifier"
  }

  assert {
    condition     = aws_lambda_function.rds-scheduler.timeout == 300
    error_message = "Lambda timeout must be 300 seconds"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.up-schedule.name == "test-cluster-app-up-schedule"
    error_message = "Up schedule rule name must include identifier"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.down-schedule.name == "test-cluster-app-down-schedule"
    error_message = "Down schedule rule name must include identifier"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.up-schedule.schedule_expression == "cron(50 10 ? * MON-FRI *)"
    error_message = "Up schedule must wrap cron fields in cron()"
  }

  assert {
    condition     = aws_cloudwatch_event_rule.down-schedule.schedule_expression == "cron(0 1 * * ? *)"
    error_message = "Down schedule must wrap cron fields in cron()"
  }

  assert {
    condition     = aws_iam_role.rds-scheduler.name == "test-cluster-app-rds-scheduler"
    error_message = "IAM role name must include identifier"
  }
}
