
terraform {
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

# --------------------------------------------------
# EXISTING DEFAULT VPC
# --------------------------------------------------

data "aws_vpc" "default" {
  default = true
}

locals {
  existing_subnet_id = "subnet-0f20c67814131e27c"
}

# --------------------------------------------------
# IAM ROLE FOR EC2 SESSION MANAGER
# --------------------------------------------------

resource "aws_iam_role" "ec2_ssm" {
  name        = "SecureDevSecOpsEC2SSMRole"
  description = "Allows the DevSecOps demo EC2 instance to use AWS Systems Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Project = "secure-devsecops-aws"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "SecureDevSecOpsEC2SSMProfile"
  role = aws_iam_role.ec2_ssm.name

  tags = {
    Project = "secure-devsecops-aws"
  }
}

# --------------------------------------------------
# SECURITY GROUP
# --------------------------------------------------

resource "aws_security_group" "juice_shop" {
  name        = "secure-devsecops-juice-shop"
  description = "Restricted access for the DevSecOps demo"
  vpc_id      = data.aws_vpc.default.id

  # SSH access - restrict to your current public IP
  ingress {
    description = "SSH access from approved IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  # Juice Shop web application
  ingress {
    description = "Juice Shop access from approved IP only"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ip]
  }

  # Outbound access for package installation, GHCR, and SSM
  egress {
    description = "Outbound access for package installation, GHCR, and SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "secure-devsecops-juice-shop"
    Project = "secure-devsecops-aws"
  }
}

# --------------------------------------------------
# EC2 INSTANCE - OWASP JUICE SHOP
# --------------------------------------------------

resource "aws_instance" "juice_shop" {
  # Existing instance AMI
  ami           = "ami-022374b883d9d7931"
  instance_type = var.instance_type

  subnet_id                   = local.existing_subnet_id
  vpc_security_group_ids      = [aws_security_group.juice_shop.id]
  associate_public_ip_address = true

  key_name             = "secure-devsecops-key"
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm.name

  # A user-data change can force EC2 replacement.
  user_data_replace_on_change = true

  # Preserve the original EC2 bootstrap script.
  user_data = <<-EOF
    #!/bin/bash
    set -Eeuo pipefail

    exec > >(tee -a /var/log/juice-shop-bootstrap.log | logger -t juice-shop-bootstrap -s 2>/dev/console) 2>&1

    echo "===== Bootstrap started: $(date -Is) ====="

    # Install Docker.
    dnf install -y docker

    # Ensure the SSM Agent is installed.
    if ! rpm -q amazon-ssm-agent >/dev/null 2>&1; then
      dnf install -y amazon-ssm-agent
    fi

    # Start and enable required services.
    systemctl enable --now amazon-ssm-agent
    systemctl enable --now docker

    # Wait for Docker to become available.
    for attempt in $(seq 1 30); do
      if docker info >/dev/null 2>&1; then
        break
      fi

      echo "Waiting for Docker (attempt $attempt/30)"
      sleep 5
    done

    docker info

    # Pull the public application image with retries.
    IMAGE="ghcr.io/preethamnn/secure-devsecops-aws:latest"
    PULLED=false

    for attempt in $(seq 1 5); do
      if docker pull "$IMAGE"; then
        PULLED=true
        break
      fi

      echo "Image pull failed (attempt $attempt/5)"
      sleep 10
    done

    if [ "$PULLED" != "true" ]; then
      echo "ERROR: Unable to pull the application image."
      exit 1
    fi

    # Replace any existing container and start Juice Shop.
    docker rm -f juice-shop || true

    docker run -d \
      --restart unless-stopped \
      --name juice-shop \
      -p 3000:3000 \
      "$IMAGE"

    # Wait for the application to respond locally.
    for attempt in $(seq 1 30); do
      if curl --fail --silent http://127.0.0.1:3000/ >/dev/null; then
        echo "Juice Shop responded successfully."
        docker ps --filter name=juice-shop
        echo "===== Bootstrap completed: $(date -Is) ====="
        exit 0
      fi

      echo "Waiting for Juice Shop HTTP response (attempt $attempt/30)"
      sleep 10
    done

    echo "ERROR: Juice Shop did not respond within the startup timeout."
    docker ps -a
    docker logs --tail 100 juice-shop || true
    exit 1
  EOF

  # Encrypted root disk
  root_block_device {
    encrypted   = true
    volume_size = 12
    volume_type = "gp3"
  }

  # Require IMDSv2 for instance metadata access
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags = {
    Name    = "secure-devsecops-juice-shop"
    Project = "secure-devsecops-aws"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# --------------------------------------------------
# OUTPUTS
# --------------------------------------------------

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.juice_shop.id
}

output "public_ip" {
  description = "Public IP address of the Juice Shop EC2 instance"
  value       = aws_instance.juice_shop.public_ip
}

output "application_url" {
  description = "Juice Shop application URL"
  value       = "http://${aws_instance.juice_shop.public_ip}:3000"
}

output "ssm_role_name" {
  description = "IAM role used by EC2 for Systems Manager"
  value       = aws_iam_role.ec2_ssm.name
}