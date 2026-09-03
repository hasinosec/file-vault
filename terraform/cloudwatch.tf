# Application logs.
resource "aws_cloudwatch_log_group" "file_vault" {
  name              = "/file-vault/application"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.file_vault.arn

  # checkov:skip=CKV_AWS_338: 30-day retention is a deliberate cost choice for a learning project (policy wants >= 1 year).
}

# Lets the EC2 CloudWatch Agent send logs to CloudWatch.
resource "aws_iam_role_policy_attachment" "file_vault_cloudwatch_agent" {
  role       = aws_iam_role.file_vault_app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Shows an alarm if EC2 CPU stays above 80% for five minutes.
resource "aws_cloudwatch_metric_alarm" "file_vault_high_cpu" {
  alarm_name          = "file-vault-high-cpu"
  alarm_description   = "File Vault EC2 CPU is high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    InstanceId = aws_instance.file_vault.id
  }
}
