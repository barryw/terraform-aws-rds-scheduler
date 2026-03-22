# terraform-aws-rds-scheduler

Terraform module to schedule start/stop of AWS RDS instances and clusters. Uses a Lambda function triggered by CloudWatch Event rules on a cron schedule.

Designed for dev/staging environments to save costs by shutting down RDS outside business hours.

## Compatibility

- Terraform >= 1.5
- OpenTofu >= 1.6
- AWS Provider >= 5.0

Use version `~> 2.0` for Terraform 0.12–1.4. Use version `~> 1.1` for Terraform <= 0.11.

## Usage

```hcl
module "rds_schedule" {
  source = "github.com/barryw/terraform-aws-rds-scheduler?ref=v3.0.0"

  identifier     = "${var.product_name}-${var.environment}"
  rds_identifier = data.aws_rds_cluster.rds.cluster_identifier
  is_cluster     = true

  # Don't stop RDS in production!
  skip_execution = var.environment == "prod"

  # Start at 6:50am EDT Mon-Fri, stop at 9pm EDT every night (UTC)
  up_schedule   = "50 10 ? * MON-FRI *"
  down_schedule = "0 1 * * ? *"
}
```

> **Note:** Cron schedules are specified in UTC using [AWS CloudWatch cron syntax](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-cron-expressions.html) (6 fields). Pass the cron fields only — the module wraps them in `cron()`.

## Instance Mode

For standalone RDS instances (non-Aurora), set `is_cluster = false`:

```hcl
module "rds_schedule" {
  source = "github.com/barryw/terraform-aws-rds-scheduler?ref=v3.0.0"

  identifier     = "my-app-staging"
  rds_identifier = data.aws_db_instance.rds.identifier
  is_cluster     = false

  up_schedule   = "50 10 ? * MON-FRI *"
  down_schedule = "0 1 * * ? *"
}
```

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->

## License

MIT — see [LICENSE](LICENSE).
