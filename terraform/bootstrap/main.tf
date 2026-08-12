# Creates the S3 bucket that holds remote Terraform state for the EKS
# configuration.
#
# This exists as its own configuration because of a chicken-and-egg problem:
# Terraform cannot store its state in a bucket that Terraform has not created
# yet. So this one config keeps its state locally (the state it produces is a
# single bucket, trivially recreated) and everything else uses the bucket.
#
# There is no DynamoDB lock table. Terraform 1.10+ supports native S3 state
# locking via a lock file held in the bucket itself, which removes a whole
# resource and its cost.

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique across all AWS accounts, so the account ID
  # and region are folded in to avoid collisions.
  bucket_name = coalesce(
    var.bucket_name,
    "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}-${var.region}"
  )

  tags = merge(
    {
      Project   = var.project
      ManagedBy = "terraform"
      Component = "tfstate"
    },
    var.tags,
  )
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
  tags   = local.tags

  # State is the record of what exists in the account. Losing it means
  # rebuilding by hand, so deletion has to be a deliberate act.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is what makes a corrupted or truncated state recoverable: every
# write keeps the previous object as a restorable version.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# State files contain resource attributes in plain text, including anything
# marked sensitive. This bucket must never be publicly reachable.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Old versions accumulate on every apply. Keeping 90 days is enough to recover
# from a bad run without paying to store state from a year ago.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Reject any request that did not arrive over TLS. Without this a
# misconfigured client could transmit state — and the credentials inside it —
# in the clear.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
