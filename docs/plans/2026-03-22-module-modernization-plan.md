# RDS Scheduler Module Modernization — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Modernize terraform-aws-rds-scheduler from v2 (TF 0.12, Python 3.7, no CI) to v3.0.0 (TF >= 1.5 / OpenTofu >= 1.6, Python 3.12, Woodpecker CI, cog releases, full test suite).

**Architecture:** Same module API — 6 Terraform variables in, 6 outputs out. Internals restructured: `main.tf` split into `versions.tf` + `iam.tf` + `main.tf`. Lambda rewritten with type hints, structured JSON logging, retry with backoff, and transitional RDS state handling. CI pipeline runs tflint, trivy, checkov, pytest, and terraform test on every push. Releases via cog conventional commits + GitHub releases on tag push.

**Tech Stack:** Terraform >= 1.5, AWS provider >= 5.0, Python 3.12, pytest, Terratest (Go), Woodpecker CI v2, cocogitto, tflint, trivy, checkov, terraform-docs.

---

### Task 1: Project Scaffolding

**Files:**
- Modify: `.gitignore`
- Create: `cog.toml`
- Create: `pyproject.toml`

**Step 1: Update `.gitignore`**

Replace the contents of `.gitignore` with:

```
# Terraform
.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
rds-scheduler.zip

# Python
__pycache__/
*.pyc
*.pyo
.pytest_cache/
*.egg-info/

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store
```

**Step 2: Create `cog.toml`**

```toml
from_latest_tag = true
ignore_merge_commits = true
tag_prefix = "v"

pre_bump_hooks = [
  "cog changelog --at {{version}} > CHANGELOG.md",
  "git add CHANGELOG.md",
]

post_bump_hooks = []

[changelog]
path = "CHANGELOG.md"
template = "remote"
remote = "github.com"
repository = "terraform-aws-rds-scheduler"
owner = "barryw"
```

**Step 3: Create `pyproject.toml`**

```toml
[tool.pytest.ini_options]
testpaths = ["tests/python"]
pythonpath = ["package"]
```

**Step 4: Create directory structure**

Run:
```bash
mkdir -p tests/python tests/terratest
```

**Step 5: Commit**

```bash
git add .gitignore cog.toml pyproject.toml
git commit -m "build: add project scaffolding for v3 modernization

Add cog.toml for conventional commits, pyproject.toml for pytest
config, update .gitignore for Terraform/Python/IDE artifacts,
create test directory structure."
```

---

### Task 2: Lambda Tests (TDD — Tests First)

**Files:**
- Create: `tests/python/conftest.py`
- Create: `tests/python/test_rds_scheduler.py`

**Step 1: Create `tests/python/conftest.py`**

```python
"""Shared fixtures for rds_scheduler tests."""
from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def rds_client() -> MagicMock:
    """Mock boto3 RDS client."""
    return MagicMock()


@pytest.fixture
def env_vars():
    """Standard environment variables for a cluster-mode deployment."""
    variables = {
        "RDS_IDENTIFIER": "test-db",
        "IS_CLUSTER": "true",
        "SKIP_EXECUTION": "false",
        "START_EVENT_ARN": "arn:aws:events:us-east-1:123456789012:rule/test-start",
        "STOP_EVENT_ARN": "arn:aws:events:us-east-1:123456789012:rule/test-stop",
    }
    with patch.dict(os.environ, variables, clear=False):
        yield variables


@pytest.fixture
def start_event(env_vars: dict) -> dict:
    """CloudWatch event that triggers a start."""
    return {"resources": [env_vars["START_EVENT_ARN"]]}


@pytest.fixture
def stop_event(env_vars: dict) -> dict:
    """CloudWatch event that triggers a stop."""
    return {"resources": [env_vars["STOP_EVENT_ARN"]]}
```

**Step 2: Create `tests/python/test_rds_scheduler.py`**

```python
"""Tests for rds_scheduler Lambda function."""
from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

import pytest
from botocore.exceptions import ClientError

from rds_scheduler import (
    ConfigurationError,
    RDSAPIError,
    RDSSchedulerError,
    _retry_with_backoff,
    _validate_config,
    get_rds_status,
    lambda_handler,
    start_rds,
    stop_rds,
)


# --- Exception hierarchy ---


class TestExceptions:
    def test_configuration_error_is_rds_scheduler_error(self):
        assert issubclass(ConfigurationError, RDSSchedulerError)

    def test_rds_api_error_is_rds_scheduler_error(self):
        assert issubclass(RDSAPIError, RDSSchedulerError)


# --- _validate_config ---


class TestValidateConfig:
    def test_valid_config(self, env_vars: dict):
        config = _validate_config()
        assert config["rds_identifier"] == "test-db"
        assert config["is_cluster"] is True
        assert config["skip_execution"] is False
        assert config["start_event_arn"] == env_vars["START_EVENT_ARN"]
        assert config["stop_event_arn"] == env_vars["STOP_EVENT_ARN"]

    def test_missing_rds_identifier(self):
        with patch.dict(os.environ, {"START_EVENT_ARN": "x", "STOP_EVENT_ARN": "y"}, clear=True):
            with pytest.raises(ConfigurationError, match="RDS_IDENTIFIER"):
                _validate_config()

    def test_missing_start_event_arn(self):
        with patch.dict(os.environ, {"RDS_IDENTIFIER": "x", "STOP_EVENT_ARN": "y"}, clear=True):
            with pytest.raises(ConfigurationError, match="START_EVENT_ARN"):
                _validate_config()

    def test_missing_stop_event_arn(self):
        with patch.dict(os.environ, {"RDS_IDENTIFIER": "x", "START_EVENT_ARN": "y"}, clear=True):
            with pytest.raises(ConfigurationError, match="STOP_EVENT_ARN"):
                _validate_config()

    def test_is_cluster_defaults_to_true(self):
        with patch.dict(
            os.environ,
            {"RDS_IDENTIFIER": "x", "START_EVENT_ARN": "y", "STOP_EVENT_ARN": "z"},
            clear=True,
        ):
            config = _validate_config()
            assert config["is_cluster"] is True

    def test_is_cluster_false(self, env_vars: dict):
        with patch.dict(os.environ, {"IS_CLUSTER": "false"}):
            config = _validate_config()
            assert config["is_cluster"] is False

    def test_skip_execution_true_string(self, env_vars: dict):
        with patch.dict(os.environ, {"SKIP_EXECUTION": "true"}):
            config = _validate_config()
            assert config["skip_execution"] is True

    def test_skip_execution_1(self, env_vars: dict):
        with patch.dict(os.environ, {"SKIP_EXECUTION": "1"}):
            config = _validate_config()
            assert config["skip_execution"] is True

    def test_skip_execution_defaults_to_false(self):
        with patch.dict(
            os.environ,
            {"RDS_IDENTIFIER": "x", "START_EVENT_ARN": "y", "STOP_EVENT_ARN": "z"},
            clear=True,
        ):
            config = _validate_config()
            assert config["skip_execution"] is False


# --- get_rds_status ---


class TestGetRdsStatus:
    def test_cluster_available(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "available"}]
        }
        assert get_rds_status(rds_client, "test-db", True) == "available"

    def test_cluster_stopped(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "stopped"}]
        }
        assert get_rds_status(rds_client, "test-db", True) == "stopped"

    def test_instance_available(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {
            "DBInstances": [{"DBInstanceStatus": "available"}]
        }
        assert get_rds_status(rds_client, "test-db", False) == "available"

    def test_instance_stopped(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {
            "DBInstances": [{"DBInstanceStatus": "stopped"}]
        }
        assert get_rds_status(rds_client, "test-db", False) == "stopped"

    def test_cluster_not_found_raises(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {"DBClusters": []}
        with pytest.raises(RDSAPIError, match="not found"):
            get_rds_status(rds_client, "test-db", True)

    def test_instance_not_found_raises(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {"DBInstances": []}
        with pytest.raises(RDSAPIError, match="not found"):
            get_rds_status(rds_client, "test-db", False)


# --- stop_rds ---


class TestStopRds:
    def test_stop_available_cluster(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "available"}]
        }
        stop_rds(rds_client, "test-db", True)
        rds_client.stop_db_cluster.assert_called_once_with(
            DBClusterIdentifier="test-db"
        )

    def test_stop_available_instance(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {
            "DBInstances": [{"DBInstanceStatus": "available"}]
        }
        stop_rds(rds_client, "test-db", False)
        rds_client.stop_db_instance.assert_called_once_with(
            DBInstanceIdentifier="test-db"
        )

    def test_stop_already_stopped_is_noop(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "stopped"}]
        }
        stop_rds(rds_client, "test-db", True)
        rds_client.stop_db_cluster.assert_not_called()

    def test_stop_in_transient_state_stopping(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "stopping"}]
        }
        stop_rds(rds_client, "test-db", True)
        rds_client.stop_db_cluster.assert_not_called()

    def test_stop_in_transient_state_modifying(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {
            "DBInstances": [{"DBInstanceStatus": "modifying"}]
        }
        stop_rds(rds_client, "test-db", False)
        rds_client.stop_db_instance.assert_not_called()

    def test_stop_in_transient_state_starting(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "starting"}]
        }
        stop_rds(rds_client, "test-db", True)
        rds_client.stop_db_cluster.assert_not_called()

    def test_stop_in_transient_state_backing_up(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {
            "DBInstances": [{"DBInstanceStatus": "backing-up"}]
        }
        stop_rds(rds_client, "test-db", False)
        rds_client.stop_db_instance.assert_not_called()


# --- start_rds ---


class TestStartRds:
    def test_start_stopped_cluster(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "stopped"}]
        }
        start_rds(rds_client, "test-db", True)
        rds_client.start_db_cluster.assert_called_once_with(
            DBClusterIdentifier="test-db"
        )

    def test_start_stopped_instance(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {
            "DBInstances": [{"DBInstanceStatus": "stopped"}]
        }
        start_rds(rds_client, "test-db", False)
        rds_client.start_db_instance.assert_called_once_with(
            DBInstanceIdentifier="test-db"
        )

    def test_start_already_running_is_noop(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "available"}]
        }
        start_rds(rds_client, "test-db", True)
        rds_client.start_db_cluster.assert_not_called()

    def test_start_in_transient_state_starting(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "starting"}]
        }
        start_rds(rds_client, "test-db", True)
        rds_client.start_db_cluster.assert_not_called()

    def test_start_in_transient_state_stopping(self, rds_client: MagicMock):
        rds_client.describe_db_instances.return_value = {
            "DBInstances": [{"DBInstanceStatus": "stopping"}]
        }
        start_rds(rds_client, "test-db", False)
        rds_client.start_db_instance.assert_not_called()

    def test_start_in_transient_state_modifying(self, rds_client: MagicMock):
        rds_client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "modifying"}]
        }
        start_rds(rds_client, "test-db", True)
        rds_client.start_db_cluster.assert_not_called()


# --- _retry_with_backoff ---


class TestRetryWithBackoff:
    def test_succeeds_first_try(self):
        func = MagicMock(return_value="ok")
        result = _retry_with_backoff(func, base_delay=0)
        assert result == "ok"
        assert func.call_count == 1

    def test_retries_on_throttling(self):
        error = ClientError(
            {"Error": {"Code": "Throttling", "Message": "Rate exceeded"}},
            "DescribeDBClusters",
        )
        func = MagicMock(side_effect=[error, "ok"])
        result = _retry_with_backoff(func, base_delay=0)
        assert result == "ok"
        assert func.call_count == 2

    def test_retries_on_request_limit_exceeded(self):
        error = ClientError(
            {"Error": {"Code": "RequestLimitExceeded", "Message": "Limit"}},
            "DescribeDBClusters",
        )
        func = MagicMock(side_effect=[error, error, "ok"])
        result = _retry_with_backoff(func, base_delay=0)
        assert result == "ok"
        assert func.call_count == 3

    def test_raises_after_max_retries_exhausted(self):
        error = ClientError(
            {"Error": {"Code": "Throttling", "Message": "Rate exceeded"}},
            "DescribeDBClusters",
        )
        func = MagicMock(side_effect=error)
        with pytest.raises(ClientError):
            _retry_with_backoff(func, max_retries=2, base_delay=0)
        assert func.call_count == 3  # initial + 2 retries

    def test_does_not_retry_non_transient_error(self):
        error = ClientError(
            {"Error": {"Code": "DBClusterNotFoundFault", "Message": "not found"}},
            "DescribeDBClusters",
        )
        func = MagicMock(side_effect=error)
        with pytest.raises(ClientError):
            _retry_with_backoff(func, base_delay=0)
        assert func.call_count == 1

    def test_passes_args_and_kwargs_to_func(self):
        func = MagicMock(return_value="ok")
        _retry_with_backoff(func, "arg1", "arg2", key="val", base_delay=0)
        func.assert_called_once_with("arg1", "arg2", key="val")


# --- lambda_handler ---


class TestLambdaHandler:
    @patch("rds_scheduler._get_rds_client")
    def test_start_event_starts_stopped_cluster(
        self, mock_get_client: MagicMock, env_vars: dict, start_event: dict
    ):
        client = MagicMock()
        mock_get_client.return_value = client
        client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "stopped"}]
        }
        lambda_handler(start_event, None)
        client.start_db_cluster.assert_called_once_with(
            DBClusterIdentifier="test-db"
        )

    @patch("rds_scheduler._get_rds_client")
    def test_stop_event_stops_available_cluster(
        self, mock_get_client: MagicMock, env_vars: dict, stop_event: dict
    ):
        client = MagicMock()
        mock_get_client.return_value = client
        client.describe_db_clusters.return_value = {
            "DBClusters": [{"Status": "available"}]
        }
        lambda_handler(stop_event, None)
        client.stop_db_cluster.assert_called_once_with(
            DBClusterIdentifier="test-db"
        )

    def test_skip_execution_does_nothing(self, env_vars: dict):
        with patch.dict(os.environ, {"SKIP_EXECUTION": "true"}):
            lambda_handler({"resources": ["anything"]}, None)

    def test_empty_resources_does_nothing(self, env_vars: dict):
        lambda_handler({"resources": []}, None)

    def test_missing_resources_key_does_nothing(self, env_vars: dict):
        lambda_handler({}, None)

    @patch("rds_scheduler._get_rds_client")
    def test_unrecognized_arn_does_not_call_client(
        self, mock_get_client: MagicMock, env_vars: dict
    ):
        event = {"resources": ["arn:aws:events:us-east-1:123456789012:rule/unknown"]}
        lambda_handler(event, None)
        mock_get_client.return_value.start_db_cluster.assert_not_called()
        mock_get_client.return_value.stop_db_cluster.assert_not_called()

    def test_missing_config_raises(self):
        with patch.dict(os.environ, {}, clear=True):
            with pytest.raises(ConfigurationError):
                lambda_handler({"resources": ["x"]}, None)

    @patch("rds_scheduler._get_rds_client")
    def test_instance_mode(self, mock_get_client: MagicMock, env_vars: dict):
        with patch.dict(os.environ, {"IS_CLUSTER": "false"}):
            client = MagicMock()
            mock_get_client.return_value = client
            client.describe_db_instances.return_value = {
                "DBInstances": [{"DBInstanceStatus": "stopped"}]
            }
            event = {"resources": [env_vars["START_EVENT_ARN"]]}
            lambda_handler(event, None)
            client.start_db_instance.assert_called_once_with(
                DBInstanceIdentifier="test-db"
            )
```

**Step 3: Run tests to verify they fail**

Run: `pytest tests/python/ -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'rds_scheduler'` (new exports don't exist yet)

**Step 4: Commit test files**

```bash
git add tests/python/conftest.py tests/python/test_rds_scheduler.py
git commit -m "test: add pytest suite for Lambda rds_scheduler

TDD step 1 — tests written before implementation.
Covers: config validation, status checks, start/stop logic,
transient state handling, retry backoff, and handler routing."
```

---

### Task 3: Lambda Implementation

**Files:**
- Modify: `package/rds_scheduler.py`

**Step 1: Rewrite `package/rds_scheduler.py`**

Replace the entire file with:

```python
"""Lambda function to start/stop an RDS instance/cluster on a schedule."""
from __future__ import annotations

import json
import logging
import os
import time
from typing import Any, Callable

import boto3
from botocore.exceptions import ClientError


# --- Exceptions ---


class RDSSchedulerError(Exception):
    """Base exception for RDS scheduler."""


class ConfigurationError(RDSSchedulerError):
    """Missing or invalid configuration."""


class RDSAPIError(RDSSchedulerError):
    """RDS API call failed after retries."""


# --- Structured JSON Logging ---


class _JSONFormatter(logging.Formatter):
    """Format log records as JSON for CloudWatch Logs Insights."""

    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "timestamp": self.formatTime(record),
            "level": record.levelname,
            "message": record.getMessage(),
        }
        if hasattr(record, "rds_identifier"):
            entry["rds_identifier"] = record.rds_identifier
        if hasattr(record, "action"):
            entry["action"] = record.action
        if record.exc_info and record.exc_info[0]:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


logger = logging.getLogger("rds_scheduler")
logger.setLevel(logging.INFO)
if not logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(_JSONFormatter())
    logger.addHandler(_handler)


# --- Constants ---

TRANSIENT_STATES = frozenset({
    "starting",
    "stopping",
    "modifying",
    "backing-up",
    "configuring-enhanced-monitoring",
    "maintenance",
    "renaming",
    "resetting-master-credentials",
})
STOPPABLE_STATES = frozenset({"available"})
STARTABLE_STATES = frozenset({"stopped"})

MAX_RETRIES = 3
BASE_DELAY = 1.0
RETRYABLE_ERROR_CODES = frozenset({
    "Throttling",
    "RequestLimitExceeded",
    "ServiceUnavailable",
})


# --- Retry ---


def _retry_with_backoff(
    func: Callable,
    *args: Any,
    max_retries: int = MAX_RETRIES,
    base_delay: float = BASE_DELAY,
    **kwargs: Any,
) -> Any:
    """Call *func* with exponential backoff on transient AWS errors."""
    for attempt in range(max_retries + 1):
        try:
            return func(*args, **kwargs)
        except ClientError as exc:
            code = exc.response["Error"]["Code"]
            if code in RETRYABLE_ERROR_CODES and attempt < max_retries:
                delay = base_delay * (2 ** attempt)
                logger.warning(
                    "Transient error '%s', retry in %.1fs (%d/%d)",
                    code,
                    delay,
                    attempt + 1,
                    max_retries,
                )
                time.sleep(delay)
            else:
                raise
    raise RDSAPIError("Exhausted retries")  # unreachable; satisfies type checker


# --- RDS helpers ---


def _get_rds_client() -> Any:
    """Return a boto3 RDS client. Separated for testability."""
    return boto3.client("rds")


def get_rds_status(client: Any, rds_identifier: str, is_cluster: bool) -> str:
    """Return the current status string of an RDS instance or cluster."""
    if is_cluster:
        resp = _retry_with_backoff(
            client.describe_db_clusters, DBClusterIdentifier=rds_identifier
        )
        clusters = resp.get("DBClusters", [])
        if not clusters:
            raise RDSAPIError(f"Cluster '{rds_identifier}' not found")
        return clusters[0]["Status"]

    resp = _retry_with_backoff(
        client.describe_db_instances, DBInstanceIdentifier=rds_identifier
    )
    instances = resp.get("DBInstances", [])
    if not instances:
        raise RDSAPIError(f"Instance '{rds_identifier}' not found")
    return instances[0]["DBInstanceStatus"]


def stop_rds(client: Any, rds_identifier: str, is_cluster: bool) -> None:
    """Stop an RDS instance or cluster if it is in a stoppable state."""
    status = get_rds_status(client, rds_identifier, is_cluster)

    if status in TRANSIENT_STATES:
        logger.warning(
            "RDS '%s' in transient state '%s', skipping stop",
            rds_identifier,
            status,
            extra={"rds_identifier": rds_identifier, "action": "stop"},
        )
        return

    if status not in STOPPABLE_STATES:
        logger.info(
            "RDS '%s' in state '%s', not stoppable",
            rds_identifier,
            status,
            extra={"rds_identifier": rds_identifier, "action": "stop"},
        )
        return

    if is_cluster:
        logger.info(
            "Stopping RDS cluster '%s'",
            rds_identifier,
            extra={"rds_identifier": rds_identifier, "action": "stop"},
        )
        _retry_with_backoff(
            client.stop_db_cluster, DBClusterIdentifier=rds_identifier
        )
    else:
        logger.info(
            "Stopping RDS instance '%s'",
            rds_identifier,
            extra={"rds_identifier": rds_identifier, "action": "stop"},
        )
        _retry_with_backoff(
            client.stop_db_instance, DBInstanceIdentifier=rds_identifier
        )


def start_rds(client: Any, rds_identifier: str, is_cluster: bool) -> None:
    """Start an RDS instance or cluster if it is in a startable state."""
    status = get_rds_status(client, rds_identifier, is_cluster)

    if status in TRANSIENT_STATES:
        logger.warning(
            "RDS '%s' in transient state '%s', skipping start",
            rds_identifier,
            status,
            extra={"rds_identifier": rds_identifier, "action": "start"},
        )
        return

    if status not in STARTABLE_STATES:
        logger.info(
            "RDS '%s' in state '%s', not startable",
            rds_identifier,
            status,
            extra={"rds_identifier": rds_identifier, "action": "start"},
        )
        return

    if is_cluster:
        logger.info(
            "Starting RDS cluster '%s'",
            rds_identifier,
            extra={"rds_identifier": rds_identifier, "action": "start"},
        )
        _retry_with_backoff(
            client.start_db_cluster, DBClusterIdentifier=rds_identifier
        )
    else:
        logger.info(
            "Starting RDS instance '%s'",
            rds_identifier,
            extra={"rds_identifier": rds_identifier, "action": "start"},
        )
        _retry_with_backoff(
            client.start_db_instance, DBInstanceIdentifier=rds_identifier
        )


# --- Configuration ---


def _validate_config() -> dict[str, Any]:
    """Validate and return all required config from environment variables."""
    rds_identifier = os.getenv("RDS_IDENTIFIER")
    if not rds_identifier:
        raise ConfigurationError("RDS_IDENTIFIER environment variable is required")

    start_event_arn = os.getenv("START_EVENT_ARN")
    if not start_event_arn:
        raise ConfigurationError("START_EVENT_ARN environment variable is required")

    stop_event_arn = os.getenv("STOP_EVENT_ARN")
    if not stop_event_arn:
        raise ConfigurationError("STOP_EVENT_ARN environment variable is required")

    skip_raw = os.getenv("SKIP_EXECUTION", "false").lower()
    skip_execution = skip_raw in ("true", "1")

    cluster_raw = os.getenv("IS_CLUSTER", "true").lower()
    is_cluster = cluster_raw in ("true", "1")

    return {
        "rds_identifier": rds_identifier,
        "is_cluster": is_cluster,
        "skip_execution": skip_execution,
        "start_event_arn": start_event_arn,
        "stop_event_arn": stop_event_arn,
    }


# --- Handler ---


def lambda_handler(event: dict[str, Any], context: Any) -> None:
    """Lambda entry point, triggered by CloudWatch Events."""
    config = _validate_config()

    logger.info(
        "Invoked",
        extra={
            "rds_identifier": config["rds_identifier"],
            "action": "init",
        },
    )

    if config["skip_execution"]:
        logger.warning("SKIP_EXECUTION is set, skipping")
        return

    resources = event.get("resources", [])
    if not resources:
        logger.warning("No resources in event, nothing to do")
        return

    source_arn = resources[0]
    client = _get_rds_client()

    if source_arn == config["start_event_arn"]:
        start_rds(client, config["rds_identifier"], config["is_cluster"])
    elif source_arn == config["stop_event_arn"]:
        stop_rds(client, config["rds_identifier"], config["is_cluster"])
    else:
        logger.warning("Unrecognized event source ARN: %s", source_arn)
```

**Step 2: Run tests to verify they pass**

Run: `pip install pytest boto3 botocore && pytest tests/python/ -v`
Expected: All 38 tests PASS.

**Step 3: Commit**

```bash
git add package/rds_scheduler.py
git commit -m "feat: rewrite Lambda to Python 3.12 with structured logging and retry

- Type hints throughout
- JSON structured logging for CloudWatch Logs Insights
- Exponential backoff retry on transient AWS errors
- Proper handling of transitional RDS states
- Config validation with clear error messages
- Custom exception hierarchy (RDSSchedulerError base)
- Same env var interface, same handler signature"
```

---

### Task 4: Terraform File Restructure

**Files:**
- Create: `versions.tf`
- Create: `iam.tf`
- Modify: `main.tf`

**Step 1: Create `versions.tf`**

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}
```

**Step 2: Create `iam.tf`**

Extract all IAM resources from `main.tf`:

```hcl
data "aws_iam_policy_document" "lambda-assume-role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds-scheduler" {
  name               = "${var.identifier}-rds-scheduler"
  assume_role_policy = data.aws_iam_policy_document.lambda-assume-role.json
}

resource "aws_iam_role_policy_attachment" "lambda-basic-execution" {
  role       = aws_iam_role.rds-scheduler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda-xray" {
  role       = aws_iam_role.rds-scheduler.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

data "aws_iam_policy_document" "rds-cluster" {
  count = var.is_cluster ? 1 : 0

  statement {
    actions = [
      "rds:DescribeDBClusters",
      "rds:StartDBCluster",
      "rds:StopDBCluster",
    ]
    resources = [
      data.aws_rds_cluster.rds-cluster[0].arn,
    ]
  }
}

data "aws_iam_policy_document" "rds-instance" {
  count = var.is_cluster ? 0 : 1

  statement {
    actions = [
      "rds:DescribeDBInstances",
      "rds:StartDBInstance",
      "rds:StopDBInstance",
    ]
    resources = [
      data.aws_db_instance.rds-instance[0].db_instance_arn,
    ]
  }
}

resource "aws_iam_policy" "rds-cluster" {
  count  = var.is_cluster ? 1 : 0
  name   = "${var.identifier}-rds-scheduler-rds-cluster"
  path   = "/"
  policy = data.aws_iam_policy_document.rds-cluster[0].json
}

resource "aws_iam_policy" "rds-instance" {
  count  = var.is_cluster ? 0 : 1
  name   = "${var.identifier}-rds-scheduler-rds-instance"
  path   = "/"
  policy = data.aws_iam_policy_document.rds-instance[0].json
}

resource "aws_iam_role_policy_attachment" "rds-cluster" {
  count      = var.is_cluster ? 1 : 0
  role       = aws_iam_role.rds-scheduler.name
  policy_arn = aws_iam_policy.rds-cluster[0].arn
}

resource "aws_iam_role_policy_attachment" "rds-instance" {
  count      = var.is_cluster ? 0 : 1
  role       = aws_iam_role.rds-scheduler.name
  policy_arn = aws_iam_policy.rds-instance[0].arn
}
```

**Step 3: Rewrite `main.tf`**

Replace entirely — only Lambda, data sources, and CloudWatch resources remain:

```hcl
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
```

**Step 4: Run `terraform fmt` and validate**

Run: `terraform fmt -recursive && terraform init -backend=false && terraform validate`
Expected: "Success! The configuration is valid."

**Step 5: Commit**

```bash
git add versions.tf iam.tf main.tf
git commit -m "refactor: restructure Terraform into versions.tf, iam.tf, main.tf

- versions.tf: TF >= 1.5, AWS provider >= 5.0, archive >= 2.0
- iam.tf: all IAM resources, trust policy as data source
- main.tf: Lambda (python3.12, arm64), CloudWatch, data sources
- Explicit tostring() for boolean env vars"
```

---

### Task 5: Variables with Validation

**Files:**
- Modify: `variables.tf`

**Step 1: Update `variables.tf`**

Replace entirely:

```hcl
variable "identifier" {
  description = "A unique name for this product/environment. Used to name all created resources."
  type        = string

  validation {
    condition     = length(var.identifier) > 0
    error_message = "identifier must not be empty."
  }

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.identifier))
    error_message = "identifier must contain only alphanumeric characters and hyphens."
  }
}

variable "skip_execution" {
  description = "Set to true to disable start/stop execution (e.g. for production environments)."
  type        = bool
  default     = false
}

variable "rds_identifier" {
  description = "The RDS identifier of the instance or cluster to schedule."
  type        = string

  validation {
    condition     = length(var.rds_identifier) > 0
    error_message = "rds_identifier must not be empty."
  }
}

variable "is_cluster" {
  description = "Set to true for an Aurora cluster, false for a standalone RDS instance."
  type        = bool
  default     = true
}

variable "up_schedule" {
  description = "Cron fields for the start schedule (6 fields, UTC). Example: '50 10 ? * MON-FRI *'"
  type        = string

  validation {
    condition     = can(regex("^[0-9*?,/LW#-]+ [0-9*?,/LW#-]+ [0-9*?,/LW#-]+ [0-9A-Z*?,/LW#-]+ [0-9A-Z*?,/LW#-]+ [0-9*?,/LW#-]+$", var.up_schedule))
    error_message = "up_schedule must be 6 space-separated cron fields (AWS CloudWatch format, UTC)."
  }
}

variable "down_schedule" {
  description = "Cron fields for the stop schedule (6 fields, UTC). Example: '0 1 * * ? *'"
  type        = string

  validation {
    condition     = can(regex("^[0-9*?,/LW#-]+ [0-9*?,/LW#-]+ [0-9*?,/LW#-]+ [0-9A-Z*?,/LW#-]+ [0-9A-Z*?,/LW#-]+ [0-9*?,/LW#-]+$", var.down_schedule))
    error_message = "down_schedule must be 6 space-separated cron fields (AWS CloudWatch format, UTC)."
  }
}
```

**Step 2: Run format and validate**

Run: `terraform fmt variables.tf && terraform validate`
Expected: "Success! The configuration is valid."

**Step 3: Commit**

```bash
git add variables.tf
git commit -m "feat: add variable validation for identifier, rds_identifier, and cron schedules

- identifier: non-empty, alphanumeric + hyphens only
- rds_identifier: non-empty
- up/down_schedule: 6 space-separated cron fields
- Improved descriptions with examples"
```

---

### Task 6: Terraform Tests

**Files:**
- Create: `tests/cluster_mode.tftest.hcl`
- Create: `tests/instance_mode.tftest.hcl`
- Create: `tests/validation.tftest.hcl`

**Step 1: Create `tests/cluster_mode.tftest.hcl`**

```hcl
mock_provider "aws" {}
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
```

**Step 2: Create `tests/instance_mode.tftest.hcl`**

```hcl
mock_provider "aws" {}
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
```

**Step 3: Create `tests/validation.tftest.hcl`**

```hcl
mock_provider "aws" {}
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
```

**Step 4: Run terraform test**

Run: `terraform init -backend=false && terraform test`
Expected: All test runs PASS.

**Step 5: Commit**

```bash
git add tests/cluster_mode.tftest.hcl tests/instance_mode.tftest.hcl tests/validation.tftest.hcl
git commit -m "test: add terraform test suite for cluster/instance modes and validation

Mock-provider plan-level tests covering resource naming, Lambda
config, env var passthrough, schedule expressions, and variable
validation rejections."
```

---

### Task 7: Documentation Setup

**Files:**
- Create: `.terraform-docs.yml`
- Modify: `README.md`

**Step 1: Create `.terraform-docs.yml`**

```yaml
formatter: markdown table

output:
  file: README.md
  mode: inject

sort:
  enabled: true
  by: required

settings:
  anchor: true
  color: true
  default: true
  description: true
  escape: true
  hide-empty: false
  html: true
  indent: 3
  lockfile: false
  read-comments: true
  required: true
  sensitive: true
  type: true
```

**Step 2: Rewrite `README.md`**

Replace entirely:

```markdown
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
```

**Step 3: Run terraform-docs to inject content**

Run: `terraform-docs .`
Expected: README.md updated with auto-generated inputs/outputs/resources between markers.

If you don't have terraform-docs installed: `brew install terraform-docs` or `go install github.com/terraform-docs/terraform-docs@v0.18.0`

**Step 4: Commit**

```bash
git add .terraform-docs.yml README.md
git commit -m "docs: add terraform-docs config and rewrite README for v3

- .terraform-docs.yml for auto-generated inputs/outputs
- README rewritten with correct usage examples
- Clarified cron field format (pass fields, not cron() wrapper)"
```

---

### Task 8: Linting Config

**Files:**
- Create: `.tflint.hcl`

**Step 1: Create `.tflint.hcl`**

```hcl
plugin "aws" {
  enabled = true
  version = "0.46.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

**Step 2: Run tflint**

Run: `tflint --init && tflint`
Expected: No errors. Review any warnings and fix if valid.

If you don't have tflint installed: `brew install tflint`

**Step 3: Commit**

```bash
git add .tflint.hcl
git commit -m "ci: add tflint config with AWS ruleset v0.46.0"
```

---

### Task 9: Woodpecker Pipeline

**Files:**
- Create: `.woodpecker.yml`

**Step 1: Create `.woodpecker.yml`**

```yaml
steps:
  - name: terraform-validate
    image: hashicorp/terraform:1.14
    depends_on: []
    commands:
      - terraform init -backend=false
      - terraform fmt -check -recursive
      - terraform validate
    when:
      - event: [push, pull_request]

  - name: cog-check
    image: ghcr.io/cocogitto/cocogitto:7.0.0
    depends_on: []
    commands:
      - cog check
    when:
      - event: pull_request

  - name: tflint
    image: ghcr.io/terraform-linters/tflint:v0.61.0
    depends_on: []
    commands:
      - tflint --init
      - tflint
    when:
      - event: [push, pull_request]

  - name: trivy
    image: aquasec/trivy:0.69.3
    depends_on: []
    commands:
      - trivy config --exit-code 1 .
    when:
      - event: [push, pull_request]

  - name: checkov
    image: bridgecrew/checkov:3.2
    depends_on: []
    commands:
      - checkov -d . --framework terraform --compact --quiet
    when:
      - event: [push, pull_request]

  - name: pytest
    image: python:3.12-slim
    depends_on: []
    commands:
      - pip install --quiet pytest boto3 botocore
      - pytest tests/python/ -v
    when:
      - event: [push, pull_request]

  - name: terraform-test
    image: hashicorp/terraform:1.14
    depends_on: []
    commands:
      - terraform init -backend=false
      - terraform test
    when:
      - event: [push, pull_request]

  - name: docs-check
    image: quay.io/terraform-docs/terraform-docs:0.18.0
    depends_on: []
    commands:
      - /terraform-docs . --output-check
    when:
      - event: [push, pull_request]

  - name: generate-changelog
    image: ghcr.io/cocogitto/cocogitto:7.0.0
    depends_on:
      - terraform-validate
      - tflint
      - trivy
      - checkov
      - pytest
      - terraform-test
      - docs-check
    commands:
      - cog changelog --at ${CI_COMMIT_TAG} > release_notes.md
    when:
      - event: tag

  - name: release
    image: plugins/github-release
    depends_on:
      - generate-changelog
    settings:
      api_key:
        from_secret: github_token
      title: ${CI_COMMIT_TAG}
      note: release_notes.md
    when:
      - event: tag
```

**Step 2: Validate YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.woodpecker.yml'))" && echo "Valid YAML"`
Expected: "Valid YAML"

> **Note:** The `release` step uses Woodpecker's `plugins/github-release` plugin. You must add a `github_token` secret in your Woodpecker repository settings. If the `note` field doesn't support file paths in your Woodpecker version, replace the `release` step with a script that uses `curl` to call the GitHub Releases API directly (see design doc for details).

**Step 3: Commit**

```bash
git add .woodpecker.yml
git commit -m "ci: add Woodpecker pipeline with parallel lint/test/security

Stages (all parallel on push/PR):
- terraform fmt/validate, tflint, trivy, checkov
- pytest (Lambda), terraform test (module)
- terraform-docs drift check, cog commit check

Release stage on tag push:
- cog changelog generation
- GitHub release via plugin

All tool versions pinned."
```

---

### Task 10: GitHub Actions Docs Workflow

**Files:**
- Create: `.github/workflows/docs.yml`

**Step 1: Create directory and workflow file**

Run: `mkdir -p .github/workflows`

Create `.github/workflows/docs.yml`:

```yaml
name: Generate terraform docs

on:
  pull_request:
    branches: [master]
    paths:
      - "*.tf"
      - ".terraform-docs.yml"

permissions:
  contents: write

jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.ref }}

      - name: Render terraform docs and push changes
        uses: terraform-docs/gh-actions@v1.3.0
        with:
          working-dir: .
          output-file: README.md
          output-method: inject
          git-push: "true"
```

**Step 2: Commit**

```bash
git add .github/workflows/docs.yml
git commit -m "ci: add GitHub Action to auto-generate terraform-docs on PRs

Triggers on PRs to master when .tf files or .terraform-docs.yml change.
Commits updated README back to the PR branch automatically."
```

---

### Task 11: Terratest Scaffold

**Files:**
- Create: `tests/terratest/go.mod`
- Create: `tests/terratest/module_test.go`

**Step 1: Create `tests/terratest/go.mod`**

```
module github.com/barryw/terraform-aws-rds-scheduler/tests/terratest

go 1.22

require (
	github.com/gruntwork-io/terratest v0.47.2
	github.com/stretchr/testify v1.9.0
)
```

**Step 2: Create `tests/terratest/module_test.go`**

```go
package test

import (
	"os"
	"testing"

	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

func skipUnlessIntegration(t *testing.T) {
	t.Helper()
	if os.Getenv("INTEGRATION_TESTS") != "true" {
		t.Skip("Set INTEGRATION_TESTS=true to run integration tests")
	}
}

// TestClusterModePlan verifies the module plans successfully in cluster mode.
// This does NOT create real AWS resources — it only runs terraform plan.
func TestClusterModePlan(t *testing.T) {
	skipUnlessIntegration(t)

	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"identifier":     "terratest-cluster",
			"rds_identifier": os.Getenv("TEST_RDS_CLUSTER_ID"),
			"is_cluster":     true,
			"up_schedule":    "0 12 ? * MON-FRI *",
			"down_schedule":  "0 0 * * ? *",
		},
		PlanFilePath: "tfplan",
	})

	plan := terraform.InitAndPlanAndShowWithStruct(t, opts)

	// Verify Lambda resource exists in plan
	lambda := plan.ResourcePlannedValuesMap["aws_lambda_function.rds-scheduler"]
	assert.NotNil(t, lambda, "Lambda function should be in plan")
	assert.Equal(t, "python3.12", lambda.AttributeValues["runtime"])

	// Verify IAM role
	role := plan.ResourcePlannedValuesMap["aws_iam_role.rds-scheduler"]
	assert.NotNil(t, role, "IAM role should be in plan")
	assert.Equal(t, "terratest-cluster-rds-scheduler", role.AttributeValues["name"])
}

// TestInstanceModePlan verifies the module plans successfully in instance mode.
func TestInstanceModePlan(t *testing.T) {
	skipUnlessIntegration(t)

	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: "../../",
		Vars: map[string]interface{}{
			"identifier":     "terratest-instance",
			"rds_identifier": os.Getenv("TEST_RDS_INSTANCE_ID"),
			"is_cluster":     false,
			"up_schedule":    "0 12 ? * MON-FRI *",
			"down_schedule":  "0 0 * * ? *",
		},
		PlanFilePath: "tfplan",
	})

	plan := terraform.InitAndPlanAndShowWithStruct(t, opts)

	lambda := plan.ResourcePlannedValuesMap["aws_lambda_function.rds-scheduler"]
	assert.NotNil(t, lambda, "Lambda function should be in plan")
}
```

**Step 3: Download Go dependencies**

Run: `cd tests/terratest && go mod tidy && cd ../..`
Expected: `go.sum` file created with resolved dependencies.

**Step 4: Commit**

```bash
git add tests/terratest/
git commit -m "test: add Terratest scaffold for integration testing

Plan-level integration tests for cluster and instance modes.
Guarded by INTEGRATION_TESTS=true env var.
Requires TEST_RDS_CLUSTER_ID and TEST_RDS_INSTANCE_ID for real
AWS targets."
```

---

### Task 12: Final Cleanup

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Update `CLAUDE.md`**

Replace entirely:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Terraform module that schedules start/stop of AWS RDS instances and clusters via a Lambda function triggered by CloudWatch Event rules. Designed for dev/staging environments to save costs.

## Architecture

A single Lambda (`package/rds_scheduler.py`) handles both start and stop. It determines the action by comparing the CloudWatch event's source ARN against `START_EVENT_ARN` and `STOP_EVENT_ARN` environment variables. The `is_cluster` variable controls a conditional split throughout: data sources, IAM policies (`iam.tf`), and Lambda behavior all branch on it via `count` (Terraform) and env var parsing (Python).

File layout:
- `versions.tf` — Terraform/provider version constraints
- `iam.tf` — IAM role, policies, and attachments
- `main.tf` — Lambda, CloudWatch rules, data sources, archive
- `variables.tf` — inputs with validation blocks
- `outputs.tf` — module outputs
- `package/rds_scheduler.py` — Lambda function (Python 3.12)

## Commands

```bash
# Terraform
terraform init -backend=false   # Init without backend (for local dev)
terraform fmt -check -recursive # Check formatting
terraform validate              # Validate config
terraform test                  # Run .tftest.hcl tests (mock providers)

# Python tests
pip install pytest boto3 botocore
pytest tests/python/ -v

# Linting
tflint --init && tflint         # Terraform linting
trivy config .                  # Security scanning
checkov -d . --framework terraform

# Docs
terraform-docs .                # Regenerate README

# Integration tests (requires AWS credentials + real RDS)
cd tests/terratest && INTEGRATION_TESTS=true go test -v -timeout 30m

# Releases
cog bump --auto                 # Auto-bump version from conventional commits
cog bump --major                # Major version bump (e.g. v3.0.0)
```

## Key Variables

- `identifier` — Names all resources (alphanumeric + hyphens, must be unique per deployment)
- `rds_identifier` — The RDS instance/cluster identifier to schedule
- `is_cluster` — Switches between cluster and instance APIs (default: true)
- `skip_execution` — Disables start/stop at runtime (default: false)
- `up_schedule` / `down_schedule` — Cron fields in UTC (6 fields, no `cron()` wrapper)

## Conventions

- Conventional commits enforced via cocogitto (`cog check`)
- All tool versions pinned in `.woodpecker.yml`
- README auto-generated by terraform-docs between `<!-- BEGIN_TF_DOCS -->` markers
- Python Lambda has zero external dependencies (boto3 provided by runtime)
```

**Step 2: Run full check suite**

Run each in sequence:
```bash
terraform fmt -check -recursive
terraform validate
terraform test
pytest tests/python/ -v
tflint --init && tflint
```
Expected: All pass.

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for v3 module structure and tooling"
```
