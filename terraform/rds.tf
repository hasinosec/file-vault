# Two private subnets for the database.
# They have no route to the public internet.
resource "aws_subnet" "private_database" {
  count = 2

  vpc_id                  = aws_vpc.file_vault.id
  cidr_block              = cidrsubnet(aws_vpc.file_vault.cidr_block, 4, count.index + 10)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "file-vault-database-private-${count.index + 1}"
  }
}

# RDS needs subnets in at least two Availability Zones.
resource "aws_db_subnet_group" "file_vault" {
  name       = "file-vault-database-subnets"
  subnet_ids = aws_subnet.private_database[*].id

  tags = {
    Name = "file-vault-database-subnets"
  }
}

# Database firewall: only the File Vault EC2 security group can connect.
resource "aws_security_group" "file_vault_database" {
  name        = "file-vault-database-security-group"
  description = "Allow PostgreSQL only from File Vault EC2"
  vpc_id      = aws_vpc.file_vault.id

  ingress {
    description     = "PostgreSQL from File Vault EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.file_vault_server.id]
  }

  tags = {
    Name = "file-vault-database-security-group"
  }
}

# Small learning PostgreSQL database.
resource "aws_db_instance" "file_vault" {
  identifier = "file-vault-postgres"

  engine         = "postgres"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 30
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.file_vault.arn

  db_name  = "filevault"
  username = "filevaultadmin"

  # AWS creates and stores the password safely in Secrets Manager.
  manage_master_user_password = true

  db_subnet_group_name    = aws_db_subnet_group.file_vault.name
  vpc_security_group_ids  = [aws_security_group.file_vault_database.id]
  publicly_accessible     = false
  backup_retention_period = 7

  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  copy_tags_to_snapshot               = true
  performance_insights_enabled        = true
  performance_insights_kms_key_id     = aws_kms_key.file_vault.arn
  enabled_cloudwatch_logs_exports     = ["postgresql", "upgrade"]

  # checkov:skip=CKV2_AWS_30: statement-level query logging is intentionally off — too noisy/costly for this project; slow-query export is enough.
  # checkov:skip=CKV_AWS_157: Multi-AZ is off on purpose — single-AZ keeps this learning stack cheap.
  multi_az = false
  # checkov:skip=CKV_AWS_293: deletion protection off so the stack can be torn down without leftover cost.
  deletion_protection = false
  # checkov:skip=CKV_AWS_118: enhanced monitoring needs a paid monitoring role; Performance Insights is enough here.
  skip_final_snapshot = true
  apply_immediately   = true

  tags = {
    Name = "file-vault-postgres"
  }
}

output "file_vault_database_address" {
  value = aws_db_instance.file_vault.address
}

output "file_vault_database_secret_arn" {
  value     = aws_db_instance.file_vault.master_user_secret[0].secret_arn
  sensitive = true
}
