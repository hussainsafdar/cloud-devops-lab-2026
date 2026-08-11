
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}


locals {
  bootstrap = <<-EOT
    #!/bin/bash
    set -eux
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y ec2-instance-connect
    snap start --enable amazon-ssm-agent || systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
  EOT
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true
  user_data                   = local.bootstrap

  tags = {
    Name = "devops-lab-bastion"
  }
}

# Static public IP so the bastion address survives stop/start and does not
# invalidate the Ansible inventory. Free while attached to a running instance.
resource "aws_eip" "bastion" {
  domain     = "vpc"
  instance   = aws_instance.bastion.id
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "devops-lab-bastion-eip"
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.app_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = var.key_pair_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  user_data              = local.bootstrap

  # NOTE: no `encrypted = true` here on purpose. Toggling encryption forces the
  # instance to be REPLACED (new instance, new private IP, re-run Ansible),
  # whereas size and type changes are applied in place with a stop/start.
  # Enable it the next time this instance is rebuilt from scratch.
  root_block_device {
    volume_size = var.app_root_volume_size
    volume_type = "gp3"
  }

  tags = {
    Name = "devops-lab-app-server"
  }
}
