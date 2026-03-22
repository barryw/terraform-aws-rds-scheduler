mock_provider "aws" {
  override_data {
    target = data.aws_iam_policy_document.lambda-assume-role
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_iam_policy_document.rds-instance
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  override_data {
    target = data.aws_db_instance.rds-instance
    values = {
      db_instance_arn = "arn:aws:rds:us-east-1:123456789012:db:my-rds-instance"
    }
  }
  override_resource {
    target = aws_iam_role.rds-scheduler
    values = {
      arn = "arn:aws:iam::123456789012:role/test-instance-app-rds-scheduler"
    }
  }
  override_resource {
    target = aws_iam_policy.rds-instance
    values = {
      arn = "arn:aws:iam::123456789012:policy/test-instance-app-rds-scheduler-rds-instance"
    }
  }
  override_resource {
    target = aws_lambda_function.rds-scheduler
    values = {
      arn = "arn:aws:lambda:us-east-1:123456789012:function:test-instance-app-rds-scheduler"
    }
  }
  override_resource {
    target = aws_cloudwatch_event_rule.up-schedule
    values = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/test-instance-app-up-schedule"
    }
  }
  override_resource {
    target = aws_cloudwatch_event_rule.down-schedule
    values = {
      arn = "arn:aws:events:us-east-1:123456789012:rule/test-instance-app-down-schedule"
    }
  }
}
mock_provider "archive" {}

variables {
  identifier     = "test-instance-app"
  rds_identifier = "my-rds-instance"
  is_cluster     = false
  up_schedule    = "0 12 ? * MON-FRI *"
  down_schedule  = "0 0 * * ? *"
}

run "instance_mode_creates_correct_resources" {
  command = plan

  assert {
    condition     = aws_lambda_function.rds-scheduler.function_name == "test-instance-app-rds-scheduler"
    error_message = "Lambda function name must include identifier"
  }

  assert {
    condition     = aws_lambda_function.rds-scheduler.runtime == "python3.12"
    error_message = "Lambda runtime must be python3.12"
  }
}

run "instance_mode_env_vars" {
  command = plan

  assert {
    condition     = aws_lambda_function.rds-scheduler.environment[0].variables["RDS_IDENTIFIER"] == "my-rds-instance"
    error_message = "RDS_IDENTIFIER env var must match rds_identifier variable"
  }

  assert {
    condition     = aws_lambda_function.rds-scheduler.environment[0].variables["IS_CLUSTER"] == "false"
    error_message = "IS_CLUSTER env var must be 'false' for instance mode"
  }
}
