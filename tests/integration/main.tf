terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name = "rds-sched-test-${random_id.suffix.hex}"
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_vpc" "default" {
  filter {
    name   = "isDefault"
    values = ["false"]
  }
}

resource "aws_db_subnet_group" "test" {
  name       = local.name
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name    = local.name
    Purpose = "integration-test"
  }
}

# Minimal RDS instance for testing — cheapest possible config
resource "aws_db_instance" "test" {
  identifier              = local.name
  engine                  = "mysql"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_subnet_group_name    = aws_db_subnet_group.test.name
  username                = "admin"
  password                = "IntTestPass8923"
  skip_final_snapshot     = true
  backup_retention_period = 0
  apply_immediately       = true
  publicly_accessible     = false

  tags = {
    Name    = local.name
    Purpose = "integration-test"
  }
}

module "scheduler" {
  source = "../../"

  depends_on = [aws_db_instance.test]

  identifier     = local.name
  rds_identifier = aws_db_instance.test.identifier
  is_cluster     = false
  up_schedule    = "0 7 * * ? *"
  down_schedule  = "0 19 * * ? *"
}
