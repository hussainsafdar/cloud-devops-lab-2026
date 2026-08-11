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

# ===========================================================================
#  >>> EDIT THIS ONE LINE WHEN YOUR WIFI / NETWORK CHANGES, THEN: terraform apply
#
#  1. curl -s https://checkip.amazonaws.com
#  2. Paste the result below, keeping the /32
#  3. terraform apply
#
#  This is the ONLY place your IP is defined. Do not also put my_ip_cidr in
#  terraform.tfvars - a .tfvars value silently overrides this default, so
#  editing here would appear to do nothing.
# ===========================================================================
variable "my_ip_cidr" {
  description = "Your public IP for SSH access to the bastion (e.g. 1.2.3.4/32)"
  type        = string
  default     = "139.135.55.206/32"

  validation {
    # Catches a bare IP with no mask, which AWS rejects with a much less
    # obvious error part-way through the apply.
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "my_ip_cidr must include a mask, e.g. 1.2.3.4/32 (a bare IP will not work)."
  }
}
