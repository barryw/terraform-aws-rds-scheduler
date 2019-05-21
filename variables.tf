variable "identifier" {
  description = "A unique name for this product/environment"
}

variable "skip_execution" {
  description = "You may not want to run this in certain environments. Set this to an expression that returns true and the associated RDS instance won't be stopped."
  default = false
}

variable "rds_identifier" {
  description = "The RDS identifier of the instance/cluster you want scheduled"
}

variable "is_cluster" {
  description = "Is this a cluster or an instance?"
  default = true
}

variable "up_schedule" {
  description = "The cron schedule for the period when you want RDS up"
}

variable "down_schedule" {
  description = "The cron schedule for the period when you want RDS down"
}
