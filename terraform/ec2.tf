data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true

  tags = {
    Name = "devops-lab-bastion"
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type           = var.instance_type
  subnet_id                = aws_subnet.private.id
  vpc_security_group_ids   = [aws_security_group.app.id]
  key_name                 = var.key_pair_name
  iam_instance_profile     = aws_iam_instance_profile.ec2_profile.name

  tags = {
    Name = "devops-lab-app-server"
  }
}
