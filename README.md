
      ____  ____  ____    ____       _              _       _
     |  _ \|  _ \/ ___|  / ___|  ___| |__   ___  __| |_   _| | ___ _ __
     | |_) | | | \___ \  \___ \ / __| '_ \ / _ \/ _` | | | | |/ _ \ '__|
     |  _ <| |_| |___) |  ___) | (__| | | |  __/ (_| | |_| | |  __/ |
     |_| \_\____/|____/  |____/ \___|_| |_|\___|\__,_|\__,_|_|\___|_|


#### Introduction

This is a Terraform module that allows you to set up a scheduled start/stop time for your RDS instances and clusters. Depending on your schedule and the size of your RDS resources, this could save you some serious money.

You'd generally want to use this in dev/staging environments where the RDS isn't always in use.

#### Versions

Use version `~> 1.1.0` for Terraform versions <= 0.11.x
Use version `~> 2.0.0` for Terraform versions >= 0.12.x

#### Usage

For Terraform versions <= 0.11.x

```hcl
module "rds_schedule" {
  source  = "github.com/barryw/terraform-aws-rds-scheduler"
  version = "~> 1.1.0"

  /* Don't stop RDS in production! */
  skip_execution = "${var.environment == "prod"}"
  identifier     = "${var.product_name}-${var.environment}"

  /* Start the RDS cluster at 6:50am EDT Monday - Friday
  up_schedule    = "cron(50 10 ? * MON-FRI *)"
  /* Stop the RDS cluster at 9pm EDT every night
  down_schedule  = "cron(0 1 * * ? *)"

  rds_identifier = "${data.aws_rds_cluster.rds.cluster_identifier}"
  is_cluster     = true
}
```

For Terraform versions >= 0.12.x

```hcl
module "rds_schedule" {
  source  = "github.com/barryw/terraform-aws-rds-scheduler"
  version = "~> 2.0.0"

  /* Don't stop RDS in production! */
  skip_execution = var.environment == "prod"
  identifier     = "${var.product_name}-${var.environment}"

  /* Start the RDS cluster at 6:50am EDT Monday - Friday
  up_schedule    = "cron(50 10 ? * MON-FRI *)"
  /* Stop the RDS cluster at 9pm EDT every night
  down_schedule  = "cron(0 1 * * ? *)"

  rds_identifier = data.aws_rds_cluster.rds.cluster_identifier
  is_cluster     = true
}
```

This example would stop RDS every night at 9pm EDT and start it every weekday morning at 6:50am EDT.

If you'd like to disable this module for certain cases, you can pass in an expression that evaluates to true for `skip_execution`

__NOTE__ The cron schedules are specified in UTC.

##### License

This module is licensed under the MIT license: https://opensource.org/licenses/MIT
