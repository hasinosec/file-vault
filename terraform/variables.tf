variable "project_name" {
  description = "Name prefix applied to every resource and tag."
  type        = string
  default     = "file-vault"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the File Vault VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "admin_cidr" {
  description = "The single public IP (as a /32 CIDR) allowed to reach SSH and the app. Set this in terraform.tfvars."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32")
    error_message = "admin_cidr must be a single-host CIDR, e.g. \"203.0.113.10/32\"."
  }
}

variable "ssh_public_key" {
  description = "Public SSH key for the EC2 key pair. Set this in terraform.tfvars; never commit a private key."
  type        = string
}
