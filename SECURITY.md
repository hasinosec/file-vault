# Security Policy

This is a personal learning project, not a production service.

## Reporting

If you spot a security issue in this repository, please open a GitHub issue with
the `security` label, or email **manhasino@gmail.com**. I will respond within a
few days.

## Scope

- Terraform in `terraform/`
- The Node.js app in `server.js`
- The CI workflow

Out of scope: any deployed instance (it is IP-restricted and short-lived).

## Handling of secrets

No credentials, keys, Terraform state, or user data are committed. The database
password is managed by AWS Secrets Manager. `data/`, `uploads/`, `*.tfvars`, and
key files are git-ignored, and gitleaks runs in CI.
