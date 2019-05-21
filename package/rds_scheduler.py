"""
Lambda function to start/stop an RDS instance/cluster on a schedule
"""
import os
import logging

import boto3

LOGGER = logging.getLogger()
LOGGER.setLevel(logging.INFO)

CLIENT = boto3.client('rds')

def stop_rds(rds_identifier, is_cluster):
    """
    Stop a RDS instance/cluster
    """
    LOGGER.info('Received STOP event.')
    status = get_rds_status(rds_identifier, is_cluster)
    if status != 'available':
        LOGGER.warning('The RDS instance/cluster is already stopped.')
        return

    if is_cluster:
        LOGGER.info('Stopping RDS cluster %s', rds_identifier)
        response = CLIENT.stop_db_cluster(DBClusterIdentifier=rds_identifier)
    else:
        LOGGER.info('Stopping RDS instance %s', rds_identifier)
        response = CLIENT.stop_db_instance(DBInstanceIdentifier=rds_identifier)

        LOGGER.debug(response)

def start_rds(rds_identifier, is_cluster):
    """
    Start a RDS instance/cluster
    """
    LOGGER.info('Received START event.')
    status = get_rds_status(rds_identifier, is_cluster)
    if status == 'available':
        LOGGER.warning('The RDS instance/cluster is already running.')
        return

    if is_cluster:
        LOGGER.info('Starting RDS cluster %s', rds_identifier)
        response = CLIENT.start_db_cluster(DBClusterIdentifier=rds_identifier)
    else:
        LOGGER.info('Starting RDS instance %s', rds_identifier)
        response = CLIENT.start_db_instance(DBInstanceIdentifier=rds_identifier)

        LOGGER.debug(response)

def get_rds_status(rds_identifier, is_cluster):
    """
    Grab the database instance/cluster
    """
    status = ""

    if is_cluster:
        response = CLIENT.describe_db_clusters(DBClusterIdentifier=rds_identifier)
        if 'DBClusters' in response and response['DBClusters']:
            cluster = response['DBClusters'][0]
            status = cluster['Status']

    else:
        response = CLIENT.describe_db_instances(DBInstanceIdentifier=rds_identifier)
        if 'DBInstances' in response and response['DBInstances']:
            instance = response['DBInstances'][0]
            status = instance['DBInstanceStatus']

    return status

def lambda_handler(event, context):
    """
    Lambda event handler
    """
    skip_execution = os.getenv('SKIP_EXECUTION') == "true" or os.getenv('SKIP_EXECUTION') == '1'
    if skip_execution:
        LOGGER.warning('SKIP_EXECUTION is set to true - skipping execution.')
        return

    rds_identifier = os.getenv('RDS_IDENTIFIER')
    is_cluster = os.getenv('IS_CLUSTER', 'false') == 'true' or os.getenv('IS_CLUSTER', '0') == '1'
    start_event_arn = os.getenv('START_EVENT_ARN')
    stop_event_arn = os.getenv('STOP_EVENT_ARN')

    LOGGER.info('RDS_IDENTIFIER=%s', rds_identifier)
    LOGGER.info('IS_CLUSTER=%s', is_cluster)
    LOGGER.info('START_EVENT_ARN=%s', start_event_arn)
    LOGGER.info('STOP_EVENT_ARN=%s', stop_event_arn)

    if not rds_identifier:
        LOGGER.fatal('You must set your RDS_IDENTIFIER appropriately.')
        return

    if 'resources' in event and event['resources']:
        source_event = event['resources'][0]
        if source_event == start_event_arn:
            start_rds(rds_identifier, is_cluster)

        if source_event == stop_event_arn:
            stop_rds(rds_identifier, is_cluster)
