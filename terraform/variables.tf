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
  description = "EC2 instance type for the bastion (it only relays SSH)"
  type        = string
  default     = "t3.micro"
}

# The app server runs the CI/CD stack. SonarQube's documented minimum is 2 GB
# on its own (it embeds Elasticsearch), plus ~1 GB Jenkins and ~256 MB Postgres,
# so t3.medium would be the correct size.
#
# Held at t3.micro to stay inside the AWS free tier. To make that survivable,
# ansible/deploy-stack.yml adds a 4 GB swap file and docker-compose.yml caps
# every JVM heap. Expect slow startup and sluggish UIs - this is under spec, not
# a recommended configuration. Change to t3.medium if the free tier stops
# mattering.
variable "app_instance_type" {
  description = "EC2 instance type for the app server running Jenkins + SonarQube"
  type        = string
  default     = "t3.micro"
}

# Default Ubuntu root volume is 8 GB, of which only ~3 GB is free - not enough
# for three images plus a 4 GB swap file. The free tier includes 30 GB of EBS,
# so this costs nothing.
variable "app_root_volume_size" {
  description = "Root volume size in GB for the app server"
  type        = number
  default     = 30
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
  default     = "125.209.81.86/32"

  validation {
    # Catches a bare IP with no mask, which AWS rejects with a much less
    # obvious error part-way through the apply.
    condition     = can(cidrhost(var.my_ip_cidr, 0))
    error_message = "my_ip_cidr must include a mask, e.g. 1.2.3.4/32 (a bare IP will not work)."
  }
}
