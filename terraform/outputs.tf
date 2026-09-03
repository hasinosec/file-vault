# Terraform prints this useful value after it creates resources.
output "file_uploads_bucket_name" {
  value = aws_s3_bucket.file_uploads.bucket
}
