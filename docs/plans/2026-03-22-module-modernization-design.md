# RDS Scheduler Module Modernization Design

## Overview

Full modernization of the terraform-aws-rds-scheduler module. Version 3.0.0 — same module API, fully modernized internals, CI/CD pipeline, proper versioning, and automated documentation.

## Terraform Module Modernization

**Version constraints and provider requirements:**
- New `versions.tf` with `required_version = ">= 1.5"` and `required_providers` block pinning `aws >= 5.0`.
- Compatible with both Terraform >= 1.5 and OpenTofu >= 1.6.
- Remove the old `terraform { required_version = ">= 0.12.0" }` from `main.tf`.

**HCL cleanup:**
- Replace inline `assume_role_policy` JSON with an `aws_iam_policy_document` data source for the Lambda trust policy.
- Update Lambda runtime from `python3.7` to `python3.12`.
- Add `architectures = ["arm64"]` to the Lambda (Graviton — cheaper and faster, no code changes needed).
- Add variable validation blocks (e.g., `rds_identifier` non-empty, cron schedule format).

**File reorganization:**
- `versions.tf` — terraform and provider version constraints
- `main.tf` — Lambda, CloudWatch rules, archive
- `iam.tf` — all IAM resources (role, policies, attachments)
- `variables.tf` — inputs with validation
- `outputs.tf` — outputs (unchanged)

No new variables, no interface changes.

## Lambda Code Modernization

**`package/rds_scheduler.py` rewrite to clean Python 3.12:**

- Type hints throughout.
- Custom exception hierarchy: base `RDSSchedulerError` with subclasses for missing config, API failures, and invalid state.

**Structured logging:**
- JSON-formatted log output via `logging.Formatter` (no external dependencies).
- Every log line includes: level, timestamp, request ID, RDS identifier, action, and outcome.

**Robustness:**
- Retry logic for transient RDS API errors (throttling, temporary unavailability) with hand-rolled exponential backoff. No external dependencies.
- Validate all environment variables at handler entry with clear error messages.
- Handle transitional RDS states (`starting`, `stopping`, `modifying`) — log appropriate messages instead of blindly calling start/stop.
- Warn on unrecognized CloudWatch event ARN instead of silently doing nothing.

**No changes:**
- No external dependencies beyond `boto3` (provided by Lambda runtime).
- Same handler signature: `lambda_handler(event, context)`.
- Same environment variable names — Terraform interface unchanged.

## Testing Strategy

### Terraform test (`tests/*.tftest.hcl`)
Fast, runs in CI on every push. Uses mock providers — no AWS credentials needed.

Test cases:
- Cluster mode (`is_cluster = true`) — correct resources planned
- Instance mode (`is_cluster = false`) — inverse resources planned
- `skip_execution` variations — variable passes through to Lambda env vars
- Variable validation — invalid inputs rejected
- Resource naming — all resources include `identifier` prefix

### Terratest (`tests/terratest/`)
Go-based integration tests against real AWS.

- Spins up actual RDS instance (`db.t4g.micro`), applies module, invokes Lambda, verifies stop/start, tears down.
- Guarded by `INTEGRATION_TESTS=true` — does not run on every push.
- `TestClusterMode` and `TestInstanceMode` variants.

### Python unit tests (`tests/python/`)
pytest with mocked boto3 (`moto` or `unittest.mock`).

Covers: start/stop logic, transitional state handling, missing env vars, retry behavior, skip execution flag, unrecognized event ARN.

## Woodpecker Pipeline & Releases

### `.woodpecker.yml` stages

**1. Validate** (every push and PR):
- `terraform fmt -check`
- `terraform validate`
- `terraform-docs` — fail if committed README is out of date
- `cog check` — fail if commits don't follow conventional commit format

**2. Lint & Security** (every push and PR):
- `tflint` with AWS ruleset
- `trivy config .`
- `checkov -d .`

**3. Test** (every push and PR):
- `pytest tests/python/`
- `terraform test`
- Terratest — only when `INTEGRATION_TESTS=true`, skipped by default

**4. Release** (tag push matching `v*`):
- `cog changelog` generates release notes from conventional commits
- Creates GitHub release with tag name, changelog body, and module source zip

### Conventional commits
- `cog.toml` at repo root defines allowed types and scopes
- `cog check` in validate stage enforces convention on PR commits

### Release workflow
Push conventional commits. When ready: `cog bump --auto` (or `--major` for v3.0.0) creates the tag locally. Push the tag. Pipeline creates the GitHub release.

## Automation & Safety Rails

### GitHub Actions terraform-docs hook (`.github/workflows/docs.yml`)
- Triggers on PRs. Runs `terraform-docs`, commits updated README back to the PR branch if changed.
- Contributors never need to remember to run terraform-docs.
- Woodpecker validate stage still checks as a safety net.

### Pipeline safety
- **Branch protection on `master`:** Require Woodpecker checks to pass. No direct pushes.
- **Pinned tool versions:** Pipeline pins specific versions of tflint, trivy, checkov, terraform-docs, and cog. No `latest` tags — upgrades are explicit and reviewable.
- **`.terraform-docs.yml`:** Defines the README template. Header content in template, generated content (inputs, outputs, resources) injected between markers.

### What this prevents
- Forgetting to update docs — auto-generated on PR
- Bad commit messages breaking releases — caught in CI
- Security issues slipping through — three scanners
- Merging broken code — tests gate the merge
- Tool version drift — everything pinned
