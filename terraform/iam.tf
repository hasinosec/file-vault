# This is the identity the future File Vault EC2 server will use.
resource "aws_iam_role" "file_vault_app" {
  name = "file-vault-app-role"

  # Only EC2 servers can use this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

# Give the app only the S3 permissions it needs.
resource "aws_iam_role_policy" "file_vault_s3_access" {
  name = "file-vault-s3-access"
  role = aws_iam_role.file_vault_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Allows the app to see files in only the File Vault bucket.
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.file_uploads.arn
      },
      {
        # Allows the app to upload, download, and delete only its files.
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.file_uploads.arn}/*"
      },
      {
        # Needed to read and write objects encrypted with the project CMK.
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.file_vault.arn
      }
    ]
  })
}

# This is the attachment EC2 uses to receive the IAM role.
resource "aws_iam_instance_profile" "file_vault_app" {
  name = "file-vault-app-profile"
  role = aws_iam_role.file_vault_app.name
}

output "file_vault_app_role_name" {
  value = aws_iam_role.file_vault_app.name
}

# Lets EC2 read only this database password from AWS Secrets Manager.
resource "aws_iam_role_policy" "file_vault_database_secret" {
  name = "file-vault-database-secret"
  role = aws_iam_role.file_vault_app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_db_instance.file_vault.master_user_secret[0].secret_arn
    }]
  })
}
