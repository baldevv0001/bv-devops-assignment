variable "region" {
  description = "AWS region for the state bucket. Keep it the same as the region the infrastructure lives in."
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Project name, used as the prefix for the bucket."
  type        = string
  default     = "bv-devops"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project))
    error_message = "project must be 3-32 characters of lowercase letters, digits or hyphens (it becomes part of an S3 bucket name)."
  }
}

variable "bucket_name" {
  description = "Explicit bucket name. Leave null to derive one from project, account ID and region, which guarantees global uniqueness."
  type        = string
  default     = null
}

variable "noncurrent_version_retention_days" {
  description = "How long superseded state versions are kept before expiry."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_retention_days >= 7
    error_message = "Keep at least 7 days of history, or a state corruption discovered a week later is unrecoverable."
  }
}

variable "tags" {
  description = "Additional tags applied to the bucket."
  type        = map(string)
  default     = {}
}
