variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

# Default login user baked into the AMI. Ubuntu images use "ubuntu";
# Amazon Linux uses "ec2-user". Keep this in sync with ec2.tf's AMI.
variable "ssh_user" {
  description = "Default OS login user for the chosen AMI"
  type        = string
  default     = "ubuntu"
}

variable "ssm_parameter_prefix" {
  description = "SSM Parameter Store path prefix for Jenkins credentials"
  type        = string
  default     = "/devops-lab/jenkins"
}

variable "key_pair_name" {
  description = "Existing AWS key pair name for SSH access"
  type        = string
}

# No default on purpose: a stale hardcoded IP here silently locks you out of the
# bastion. Set it in terraform.tfvars and refresh it when your ISP IP changes
# (curl -s https://checkip.amazonaws.com).
variable "my_ip_cidr" {
  description = "Your public IP address for SSH access (e.g. 1.2.3.4/32)"
  type        = string
}
