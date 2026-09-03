# Stores uploaded files. Bucket names must be globally unique, so the account ID
# is appended at plan time rather than hard-coded.
resource "aws_s3_bucket" "file_uploads" {
  bucket = "${var.project_name}-${data.aws_caller_identity.current.account_id}"

  # checkov:skip=CKV_AWS_18: server access logging needs a second log bucket — deferred, tracked in THREAT_MODEL.md.
  # checkov:skip=CKV_AWS_144: cross-region replication is out of scope for a single-region learning project.
  # checkov:skip=CKV2_AWS_62: no event-notification consumer exists in this project.
}

# Block public access. Users must never access all uploaded files publicly.
resource "aws_s3_bucket_public_access_block" "file_uploads" {
  bucket = aws_s3_bucket.file_uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt files while AWS stores them.
resource "aws_s3_bucket_server_side_encryption_configuration" "file_uploads" {
  bucket = aws_s3_bucket.file_uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.file_vault.arn
    }
    bucket_key_enabled = true
  }
}

# Keep older versions if somebody overwrites a file by mistake.
resource "aws_s3_bucket_versioning" "file_uploads" {
  bucket = aws_s3_bucket.file_uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Expire noncurrent versions so old copies do not accumulate forever.
resource "aws_s3_bucket_lifecycle_configuration" "file_uploads" {
  bucket = aws_s3_bucket.file_uploads.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Reject any request that is not over TLS.
resource "aws_s3_bucket_policy" "file_uploads_tls_only" {
  bucket = aws_s3_bucket.file_uploads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.file_uploads.arn,
        "${aws_s3_bucket.file_uploads.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}
