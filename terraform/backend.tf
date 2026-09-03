# Remote state backend.
#
# State is kept locally by default so the project runs with zero setup. For any
# shared or long-lived use, move state to an encrypted, locked S3 backend:
#
#   1. Create the bucket and lock table once (separate `terraform apply` or CLI):
#        aws s3api create-bucket --bucket <project>-tfstate-<account_id> --region us-east-1
#        aws s3api put-bucket-versioning --bucket <project>-tfstate-<account_id> \
#            --versioning-configuration Status=Enabled
#        aws s3api put-bucket-encryption --bucket <project>-tfstate-<account_id> \
#            --server-side-encryption-configuration \
#            '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}'
#        aws dynamodb create-table --table-name <project>-tflock \
#            --attribute-definitions AttributeName=LockID,AttributeType=S \
#            --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST
#
#   2. Uncomment the block below, fill in the names, and run `terraform init -migrate-state`.
#
# terraform {
#   backend "s3" {
#     bucket         = "file-vault-tfstate-<account_id>"
#     key            = "file-vault/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "file-vault-tflock"
#     encrypt        = true
#   }
# }
