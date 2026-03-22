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
### Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0 |

### Providers

| Name | Version |
|------|---------|
| <a name="provider_archive"></a> [archive](#provider\_archive) | >= 2.0 |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0 |

### Modules

No modules.

### Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_event_rule.down-schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_rule.up-schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.down-schedule-target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_event_target.up-schedule-target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_iam_policy.rds-cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.rds-instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.rds-scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.lambda-basic-execution](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda-xray](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.rds-cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.rds-instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.rds-scheduler](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.down-schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.up-schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [archive_file.rds-scheduler](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_db_instance.rds-instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/db_instance) | data source |
| [aws_iam_policy_document.lambda-assume-role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.rds-cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.rds-instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_rds_cluster.rds-cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/rds_cluster) | data source |

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_down_schedule"></a> [down\_schedule](#input\_down\_schedule) | Cron fields for the stop schedule (6 fields, UTC). Example: '0 1 * * ? *' | `string` | n/a | yes |
| <a name="input_identifier"></a> [identifier](#input\_identifier) | A unique name for this product/environment. Used to name all created resources. | `string` | n/a | yes |
| <a name="input_rds_identifier"></a> [rds\_identifier](#input\_rds\_identifier) | The RDS identifier of the instance or cluster to schedule. | `string` | n/a | yes |
| <a name="input_up_schedule"></a> [up\_schedule](#input\_up\_schedule) | Cron fields for the start schedule (6 fields, UTC). Example: '50 10 ? * MON-FRI *' | `string` | n/a | yes |
| <a name="input_is_cluster"></a> [is\_cluster](#input\_is\_cluster) | Set to true for an Aurora cluster, false for a standalone RDS instance. | `bool` | `true` | no |
| <a name="input_skip_execution"></a> [skip\_execution](#input\_skip\_execution) | Set to true to disable start/stop execution (e.g. for production environments). | `bool` | `false` | no |

### Outputs

| Name | Description |
|------|-------------|
| <a name="output_down_schedule_rule_arn"></a> [down\_schedule\_rule\_arn](#output\_down\_schedule\_rule\_arn) | The arn of the down schedule rule |
| <a name="output_down_schedule_target_arn"></a> [down\_schedule\_target\_arn](#output\_down\_schedule\_target\_arn) | The arn of the down schedule target |
| <a name="output_scheduler_lambda_arn"></a> [scheduler\_lambda\_arn](#output\_scheduler\_lambda\_arn) | The arn of the start/stop Lambda function |
| <a name="output_scheduler_role_arn"></a> [scheduler\_role\_arn](#output\_scheduler\_role\_arn) | The arn of the role created for the start/stop Lambda |
| <a name="output_up_schedule_rule_arn"></a> [up\_schedule\_rule\_arn](#output\_up\_schedule\_rule\_arn) | The arn of the up schedule rule |
| <a name="output_up_schedule_target_arn"></a> [up\_schedule\_target\_arn](#output\_up\_schedule\_target\_arn) | The arn of the up schedule target |
<!-- END_TF_DOCS -->

## License

MIT — see [LICENSE](LICENSE).
