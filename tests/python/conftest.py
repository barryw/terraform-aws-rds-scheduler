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
