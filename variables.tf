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
