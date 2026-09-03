# Find available AWS Availability Zones in us-east-1.
data "aws_availability_zones" "available" {
  state = "available"
}

# The main private network for File Vault.
resource "aws_vpc" "file_vault" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "file-vault-vpc"
  }
}

# Lock the default security group down to no traffic at all; nothing should use it.
resource "aws_default_security_group" "file_vault" {
  vpc_id = aws_vpc.file_vault.id

  tags = {
    Name = "file-vault-default-do-not-use"
  }
}

# --- VPC flow logs -> CloudWatch, for network investigation ---
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/file-vault/vpc-flow-logs"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.file_vault.arn

  # checkov:skip=CKV_AWS_338: 30-day retention is a deliberate cost choice for a learning project (policy wants >= 1 year).
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.project_name}-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.project_name}-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "file_vault" {
  vpc_id          = aws_vpc.file_vault.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
}

# Lets public resources in this VPC reach the internet.
resource "aws_internet_gateway" "file_vault" {
  vpc_id = aws_vpc.file_vault.id

  tags = {
    Name = "file-vault-internet-gateway"
  }
}

# Two public subnets in different Availability Zones.
# Later, an EC2 server or load balancer can use these.
resource "aws_subnet" "public" {
  count = 2

  vpc_id            = aws_vpc.file_vault.id
  cidr_block        = cidrsubnet(aws_vpc.file_vault.cidr_block, 4, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  # checkov:skip=CKV_AWS_130: this subnet is deliberately public — it hosts the single web server, with no NAT gateway by design.
  map_public_ip_on_launch = true

  tags = {
    Name = "file-vault-public-${count.index + 1}"
  }
}

# Routing table for public subnets.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.file_vault.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.file_vault.id
  }

  tags = {
    Name = "file-vault-public-routes"
  }
}

# Connect both public subnets to the public routing table.
resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

output "file_vault_vpc_id" {
  value = aws_vpc.file_vault.id
}

output "file_vault_public_subnet_ids" {
  value = aws_subnet.public[*].id
}
