
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
}

variable "aws_region" {
  description = "AWS region for the deployment"
  type        = string
  default     = "ap-south-1"
}

variable "allowed_ip" {
  description = "Your public IPv4 address in CIDR notation, for example 203.0.113.10/32"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.allowed_ip)) && can(regex("/32$", var.allowed_ip))
    error_message = "allowed_ip must be a valid IPv4 /32 CIDR."
  }
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Existing EC2 key pair name"
  type        = string
  default     = "secure-devsecops-key"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_security_group" "juice_shop" {
  name        = "secure-devsecops-juice-shop"
  description = "Restricted access for the DevSecOps demo"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from approved IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  ingress {
    description = "Juice Shop demo from approved IP only"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project = "secure-devsecops-aws"
  }
}

resource "aws_instance" "juice_shop" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.juice_shop.id]
  associate_public_ip_address = true

  root_block_device {
    encrypted   = true
    volume_size = 12
    volume_type = "gp3"
  }

    user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    dnf install -y docker
    systemctl enable --now docker

    docker pull ghcr.io/preethamnn/secure-devsecops-aws:latest

    docker run -d --restart unless-stopped \
      --name juice-shop \
      -p 3000:3000 \
      ghcr.io/preethamnn/secure-devsecops-aws:latest
  EOF

  tags = {
    Name    = "secure-devsecops-juice-shop"
    Project = "secure-devsecops-aws"
  }
}
