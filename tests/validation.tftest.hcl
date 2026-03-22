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
      arn = "arn:aws:rds:us-east-1:123456789012:cluster:my-db"
    }
  }
}
mock_provider "archive" {}

run "rejects_empty_identifier" {
  command = plan

  variables {
    identifier     = ""
    rds_identifier = "my-db"
    is_cluster     = true
    up_schedule    = "50 10 ? * MON-FRI *"
    down_schedule  = "0 1 * * ? *"
  }

  expect_failures = [
    var.identifier,
  ]
}

run "rejects_invalid_identifier_characters" {
  command = plan

  variables {
    identifier     = "test app with spaces"
    rds_identifier = "my-db"
    is_cluster     = true
    up_schedule    = "50 10 ? * MON-FRI *"
    down_schedule  = "0 1 * * ? *"
  }

  expect_failures = [
    var.identifier,
  ]
}

run "rejects_empty_rds_identifier" {
  command = plan

  variables {
    identifier     = "test-app"
    rds_identifier = ""
    is_cluster     = true
    up_schedule    = "50 10 ? * MON-FRI *"
    down_schedule  = "0 1 * * ? *"
  }

  expect_failures = [
    var.rds_identifier,
  ]
}

run "rejects_invalid_cron_schedule" {
  command = plan

  variables {
    identifier     = "test-app"
    rds_identifier = "my-db"
    is_cluster     = true
    up_schedule    = "not a cron"
    down_schedule  = "0 1 * * ? *"
  }

  expect_failures = [
    var.up_schedule,
  ]
}

run "accepts_valid_config" {
  command = plan

  variables {
    identifier     = "test-app"
    rds_identifier = "my-db"
    is_cluster     = true
    up_schedule    = "50 10 ? * MON-FRI *"
    down_schedule  = "0 1 * * ? *"
  }
}
