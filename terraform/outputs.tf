output "vpc_id" {
  value = aws_vpc.main.id
}

output "bastion_public_ip" {
  description = "Static Elastic IP of the bastion host"
  value       = aws_eip.bastion.public_ip
}

output "bastion_instance_id" {
  description = "Use with: aws ssm start-session --target <id>"
  value       = aws_instance.bastion.id
}

output "app_server_private_ip" {
  value = aws_instance.app.private_ip
}

output "app_instance_id" {
  description = "Use with: aws ssm start-session --target <id>"
  value       = aws_instance.app.id
}

output "ssh_bastion_command" {
  description = "Ready-to-paste SSH command for the bastion"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ${var.ssh_user}@${aws_eip.bastion.public_ip}"
}

output "ssh_user" {
  description = "Default login user for the AMI in use"
  value       = var.ssh_user
}
