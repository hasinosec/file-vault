# File Vault — Threat Model

Lightweight threat model for a small document-upload service on AWS. Scope: the
infrastructure in `terraform/` and the `server.js` application.

## Assets

| Asset | Why it matters |
| --- | --- |
| Uploaded documents (S3) | May contain personal or business data. Confidentiality + integrity. |
| User records (RDS) | Email + scrypt password hash. Account-takeover target. |
| Database credentials (Secrets Manager) | Full read/write to user data if leaked. |
| EC2 instance role | Path to S3 and the secret if the app is compromised. |
| CloudWatch logs | Investigation evidence; must not contain secrets. |

## Trust boundaries

```
Internet ──► [admin_cidr /32] ──► EC2 (public subnet) ──► S3  (VPC edge)
                                        │
                                        └──► RDS (private subnets, no internet route)
```

- Internet → EC2: only the single `admin_cidr` reaches ports 22 and 3000.
- EC2 → RDS: only the app security group, only 5432.
- EC2 → AWS APIs: only the actions in the instance-role policies.
- CI → anything: none. CI has no AWS credentials.

## Threats and mitigations (STRIDE-ish)

| Threat | Mitigation | Residual risk |
| --- | --- | --- |
| Credential theft via SSRF reading instance metadata | IMDSv2 required (`http_tokens = "required"`) | App-level SSRF still possible; input validation needed in app |
| Public exposure of uploaded files | S3 public access block (all four), TLS-only bucket policy, no bucket ACLs | Misconfig if future code adds a public policy — Checkov in CI guards this |
| Database exposed to the internet | Private subnets, `publicly_accessible = false`, SG restricted to app SG | None significant |
| Password in source / state / logs | Secrets Manager managed password; secret ARN output marked `sensitive` | Operators must not paste it into logs |
| Stolen SSH key | Key pair is per-project; ingress limited to one IP; SSM Session Manager is the planned replacement | Private key handling is on the operator |
| Data loss from overwrite/delete | S3 versioning; noncurrent versions kept 90 days | RDS backup retention is only 1 day (cost choice) |
| Secrets committed to Git | gitleaks in CI; `.gitignore` excludes `data/`, `uploads/`, tfstate, `*.tfvars`, keys | History was rebuilt clean before publishing |
| Vulnerable dependency / image | `npm audit` and Trivy in CI | Not blocking the build yet — planned |
| Traffic interception (HTTP only) | — | **Open.** HTTPS + WAF required before real users (see below) |

## Accepted risks (deliberate, for a cost-bounded learning environment)

- **HTTP only** — no ACM certificate, load balancer, or CloudFront yet.
- **`deletion_protection = false`, `skip_final_snapshot = true`** — so the stack tears down without leftover cost.
- **Open egress (`0.0.0.0/0`)** from the instance — needed for OS updates and S3; no NAT gateway by choice.
- **Single instance, in-memory sessions** — no high availability.

## Planned hardening

1. HTTPS via ACM + CloudFront (or ALB) and AWS WAF managed rules.
2. Replace SSH ingress with AWS SSM Session Manager.
3. GitHub OIDC → short-lived AWS role for deploys; remove any static keys.
4. Move Terraform state to the encrypted, locked S3 backend in `backend.tf`.
5. Dedicated least-privilege RDS application user instead of the master user.
6. Make Trivy / Checkov findings block the build on High/Critical.
