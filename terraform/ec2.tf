# Find a current Amazon Linux 2023 image for our EC2 server.
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# Put your public SSH key in AWS.
# Terraform reads the public key only, never the private key.
resource "aws_key_pair" "file_vault" {
  key_name = "file-vault-ec2-key"
  # The value comes from local terraform.tfvars. It is not committed to Git.
  public_key = var.ssh_public_key
}

# Firewall rules for the File Vault EC2 server.
resource "aws_security_group" "file_vault_server" {
  name        = "file-vault-server-security-group"
  description = "Allow SSH and learning-app access only from the owner"
  vpc_id      = aws_vpc.file_vault.id

  # SSH access: only from your current public IP.
  ingress {
    description = "SSH from owner"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Temporary learning access to the File Vault app.
  # Later we will use HTTPS and allow real users safely.
  ingress {
    description = "File Vault app from owner"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # The server can download OS updates and reach the S3/Secrets Manager endpoints.
  # checkov:skip=CKV_AWS_382: open egress is accepted — there is no NAT gateway by design and the instance needs outbound for yum and AWS APIs.
  egress {
    description = "Outbound to internet for OS updates and AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "file-vault-server-security-group"
  }
}

# The virtual machine that will run File Vault.
resource "aws_instance" "file_vault" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.file_vault_server.id]
  key_name               = aws_key_pair.file_vault.key_name
  iam_instance_profile   = aws_iam_instance_profile.file_vault_app.name
  ebs_optimized          = true
  monitoring             = true

  # checkov:skip=CKV_AWS_88: this instance is the public web server; access is still limited to admin_cidr by the security group.
  associate_public_ip_address = true

  # Require IMDSv2 so the instance role cannot be read through SSRF.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    encrypted = true
  }

  tags = {
    Name = "file-vault-server"
  }
}

output "file_vault_server_public_ip" {
  value = aws_instance.file_vault.public_ip
}
