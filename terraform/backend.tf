terraform {
  backend "s3" {
    bucket         = "cloud-devops-lab-2026-tfstate-hussain"
    key            = "terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}