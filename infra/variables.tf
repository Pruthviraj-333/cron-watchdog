variable "aws_region" {
  type        = string
  description = "AWS region for deployment"
  default     = "ap-south-1"
}

variable "alert_email" {
  type        = string
  description = "Email address for SNS alert notifications and budget alarm"
  default     = "pruthvirajjanwade@gmail.com"
}

variable "operator_ip" {
  type        = string
  description = "Operator public IP address for SSH access (CIDR /32)"
  default     = "103.151.234.231/32"
}

variable "instance_type" {
  type        = string
  description = "Free-tier eligible EC2 instance type"
  default     = "t3.micro"
}

variable "key_name" {
  type        = string
  description = "Name of existing EC2 Key Pair for SSH"
  default     = "key_pair_mum"
}

variable "monthly_budget_usd" {
  type        = string
  description = "Monthly budget limit in USD"
  default     = "5.0"
}
