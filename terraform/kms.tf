# One customer-managed key, with rotation, used for the log groups, the S3
# bucket, and RDS. Keeping it to a single key keeps cost and operations simple
# while still meeting "encrypt with a CMK you control".
resource "aws_kms_key" "file_vault" {
  description             = "${var.project_name} — logs, S3, and RDS encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "file_vault" {
  name          = "alias/${var.project_name}"
  target_key_id = aws_kms_key.file_vault.key_id
}
