output "instance_id" {
  description = "EC2 Instance ID"
  value       = aws_instance.vm.id
}

output "public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.vm.public_ip
}

output "sns_topic_arn" {
  description = "ARN of the SNS alert topic"
  value       = aws_sns_topic.alerts.arn
}

output "ssh_command" {
  description = "SSH connection command"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.vm.public_ip}"
}

output "ssm_session_command" {
  description = "AWS SSM Session Manager connection command (secure, no open ports required)"
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.vm.id}"
}

