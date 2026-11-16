
variable "aws_region" {
  description = "AWS region for the DevSecOps deployment"
  type        = string
  default     = "ap-south-1"
}

variable "instance_type" {
  description = "EC2 instance type for OWASP Juice Shop"
  type        = string
  default     = "t3.micro"
}

variable "allowed_ip" {
  description = "Public IPv4 CIDR allowed to access SSH and Juice Shop"
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_ip, 0))
    error_message = "allowed_ip must be a valid IPv4 or IPv6 CIDR block."
  }
}
