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
