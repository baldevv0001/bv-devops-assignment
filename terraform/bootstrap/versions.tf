terraform {
  # 1.10 is the floor for S3-native state locking, which this setup relies on
  # instead of a DynamoDB lock table.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Intentionally no backend block: this configuration keeps its state locally.
  # It cannot store state in the bucket it is responsible for creating, and its
  # output is a single bucket that is cheap to recreate if the local state is
  # ever lost.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
