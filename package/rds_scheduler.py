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
