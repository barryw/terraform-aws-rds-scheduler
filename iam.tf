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
