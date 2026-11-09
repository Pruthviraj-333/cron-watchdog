terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      project = "cron-watchdog"
    }
  }
}

# 1. Billing / Budget Alarm ($5 USD monthly limit with email notification)
resource "aws_budgets_budget" "cost" {
  name              = "cron-watchdog-monthly-budget"
  budget_type       = "COST"
  limit_amount      = var.monthly_budget_usd
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2026-01-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

# 2. SNS Alert Topic & Email Subscription
resource "aws_sns_topic" "alerts" {
  name = "cron-watchdog-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# 3. Least-Privilege IAM Instance Role for EC2
resource "aws_iam_role" "instance" {
  name = "cron-watchdog-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# Policy allowing ONLY sns:Publish to the specific alert topic
resource "aws_iam_role_policy" "sns_publish" {
  name = "cron-watchdog-sns-publish"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowSNSPublishAlerts"
      Effect   = "Allow"
      Action   = "sns:Publish"
      Resource = aws_sns_topic.alerts.arn
    }]
  })
}

# Attach AWS SSM Managed Instance Core for secure Session Manager access
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "profile" {
  name = "cron-watchdog-instance-profile"
  role = aws_iam_role.instance.name
}

# 4. Security Group: SSH restricted only to operator IP (no 0.0.0.0/0)
resource "aws_security_group" "sg" {
  name        = "cron-watchdog-ec2-sg"
  description = "Security group for cron-watchdog EC2 testing instance"

  ingress {
    description = "SSH access restricted strictly to operator IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_ip]
  }

  egress {
    description = "Allow outbound traffic for OS updates and AWS API calls"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 5. Ubuntu 24.04 LTS AMI Data Source
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# 6. EC2 Instance (Free-tier eligible t3.micro)
resource "aws_instance" "vm" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  key_name             = var.key_name
  iam_instance_profile = aws_iam_instance_profile.profile.name
  vpc_security_group_ids = [aws_security_group.sg.id]

  root_block_device {
    volume_size           = 15
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -ex
              apt-get update
              apt-get install -y jq bats shellcheck git awscli
              mkdir -p /var/log/cron-watchdog /var/lib/cron-watchdog/heartbeats /etc/cron-watchdog
              chmod 755 /var/log/cron-watchdog /var/lib/cron-watchdog /etc/cron-watchdog
              echo "CRONWATCH_SNS_TOPIC_ARN=${aws_sns_topic.alerts.arn}" > /etc/cron-watchdog/cronwatch.env
              echo "AWS_REGION=${var.aws_region}" >> /etc/cron-watchdog/cronwatch.env
              EOF

  tags = {
    Name = "cron-watchdog-test-node"
  }
}
