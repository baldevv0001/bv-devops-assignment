terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      # The EKS module v21 requires >= 6.52.
      source  = "hashicorp/aws"
      version = "~> 6.52"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # No backend block, so state is written to ./terraform.tfstate locally.
  #
  # To move state into S3 instead: apply terraform/bootstrap to create the
  # bucket, then rename backend.tf.s3-example to backend.tf, fill in the bucket
  # name it outputs, and run `terraform init -migrate-state`.
}

provider "aws" {
  region = var.region

  # Applied to every resource the provider creates, including ones buried
  # inside modules that expose no tags argument of their own.
  default_tags {
    tags = local.tags
  }
}
