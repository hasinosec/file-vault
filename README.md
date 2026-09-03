# File Vault

[![CI](https://github.com/hasinosec/file-vault/actions/workflows/ci.yml/badge.svg)](https://github.com/hasinosec/file-vault/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A secure document-upload platform that models a small-company AWS architecture. The
point of the project is the **infrastructure and the security controls around the
app**, all managed as reviewable Terraform and checked in CI before anything ships.

![Architecture](docs/architecture.svg)

## What it demonstrates

| Area | Control |
| --- | --- |
| **Identity** | The EC2 instance runs under a least-privilege IAM role scoped to one S3 bucket, one Secrets Manager secret, and the CloudWatch Agent policy. No long-lived keys. |
| **Network** | A dedicated VPC. The database sits in private subnets with no route to the internet and a security group that only accepts PostgreSQL from the app's security group. |
| **Data at rest** | S3 bucket: encryption on, versioning on, all public access blocked, noncurrent versions expired after 90 days, and a bucket policy that denies non-TLS requests. RDS storage is encrypted. |
| **Secrets** | The database password is generated and held by AWS Secrets Manager (`manage_master_user_password`). It never appears in code, state output, or config. |
| **Instance hardening** | IMDSv2 required (`http_tokens = "required"`), encrypted root volume, detailed monitoring. |
| **Visibility** | Application logs ship to a CloudWatch log group via the CloudWatch Agent; a CPU alarm is defined. |
| **Supply chain / IaC** | Every push runs gitleaks, Checkov, tfsec, Trivy, `terraform validate`, `npm audit`, and a Docker build. CI holds no cloud credentials and cannot deploy. |

See [`THREAT_MODEL.md`](THREAT_MODEL.md) for assets, trust boundaries, and accepted risks.

## Repository layout

```
server.js                  Node.js app: auth (scrypt), upload / list / download / delete
terraform/                 all infrastructure
  provider.tf              region, default tags, caller-identity data source
  s3.tf                    private encrypted bucket + lifecycle + TLS-only policy
  iam.tf                   least-privilege EC2 role (S3, secret, CloudWatch)
  vpc.tf                   VPC, public subnets, internet gateway, routing
  ec2.tf                   instance, key pair, security group, IMDSv2, encrypted root
  rds.tf                   private subnets, subnet group, DB security group, PostgreSQL
  cloudwatch.tf            log group, CPU alarm, CloudWatch Agent permission
  backend.tf               commented S3 + DynamoDB remote-state setup
  variables.tf             project_name, aws_region, vpc_cidr, admin_cidr, ssh_public_key
  terraform.tfvars.example copy to terraform.tfvars and fill in
deploy/cloudwatch-agent.json  EC2 CloudWatch Agent config
.github/workflows/ci.yml   security + build pipeline
```

## Run the app locally

Node.js 20+, no framework — only built-in modules plus the AWS SDK and `pg`.

```bash
npm ci
S3_BUCKET=your-bucket AWS_REGION=us-east-1 npm start
# http://localhost:3000
```

Without `DATABASE_HOST` / `DATABASE_SECRET_ARN` the app falls back to a local
`data/database.json` so it runs with no AWS account. Deployed on EC2 it uses RDS
and S3 through the instance role.

## Deploy the infrastructure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set admin_cidr and ssh_public_key
terraform init
terraform fmt -check
terraform validate
terraform plan          # read every line before applying
terraform apply
```

Uses your local AWS CLI credentials. `admin_cidr` restricts SSH and the app to a
single IP. The site is HTTP-only — put HTTPS and a WAF in front before exposing it
to real users (tracked in the threat model).

## Known limitations (by design, for a cost-bounded learning build)

- HTTP only, single instance, in-memory sessions — not production-ready.
- `deletion_protection` / final snapshot are disabled so the stack can be torn down cheaply.
- No NAT gateway or load balancer (hourly cost); egress is direct from the public subnet.
