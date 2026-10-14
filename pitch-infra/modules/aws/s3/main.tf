###############################################################################
# S3 Bucket Module — Next.js App File Storage
###############################################################################

resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = var.tags
}

###############################################################################
# Object Ownership — BucketOwnerEnforced (disables ACLs)
###############################################################################

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

###############################################################################
# Block All Public Access
###############################################################################

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# Server-Side Encryption (SSE-KMS)
###############################################################################

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

###############################################################################
# Versioning
###############################################################################

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.enable_versioning ? "Enabled" : "Suspended"
  }
}

###############################################################################
# Lifecycle Rules
###############################################################################

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.enable_lifecycle_rules ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "transition-to-ia-and-glacier"
    status = "Enabled"

    filter {}

    transition {
      days          = var.ia_transition_days
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = var.glacier_transition_days
      storage_class = "GLACIER"
    }
  }
}

###############################################################################
# CORS Configuration
###############################################################################

resource "aws_s3_bucket_cors_configuration" "this" {
  count  = length(var.cors_allowed_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = var.cors_allowed_methods
    allowed_origins = var.cors_allowed_origins
    expose_headers  = ["ETag", "Content-Length", "Content-Type"]
    max_age_seconds = 3600
  }
}

###############################################################################
# Bucket Policy — Enforce SSL-Only Access
###############################################################################

data "aws_iam_policy_document" "ssl_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "ssl_only" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.ssl_only.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

###############################################################################
# Access Logging (optional)
###############################################################################

resource "aws_s3_bucket_logging" "this" {
  count  = var.logging_bucket_id != null ? 1 : 0
  bucket = aws_s3_bucket.this.id

  target_bucket = var.logging_bucket_id
  target_prefix = "${var.bucket_name}/logs/"
}
