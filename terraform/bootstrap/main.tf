# S3 bucket holding remote Terraform state for the EKS config. Kept separate
# because Terraform cannot store state in a bucket it has not created yet.
# No DynamoDB lock table: Terraform 1.10+ locks natively in S3.

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique, so fold in the account ID and region.
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

  # Losing state means rebuilding by hand, so deletion must be deliberate.
  lifecycle {
    prevent_destroy = true
  }
}

# Keeps every previous state object, so a corrupted write is recoverable.
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

# State holds resource attributes in plain text, so this must never be public.
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

# Old versions accumulate on every apply; 90 days is enough to recover.
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

# Reject non-TLS requests, which would send state over the wire in the clear.
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
