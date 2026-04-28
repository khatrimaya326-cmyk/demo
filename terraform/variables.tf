variable "aws_region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "3-tier-app"
}

variable "db_password" {
  description = "RDS master password"
  sensitive   = true
}

variable "github_org" {
  description = "GitHub organization or username"
}

variable "github_repo" {
  description = "GitHub repository name"
}

variable "tags" {
  default = {
    Project     = "3-tier-app"
    ManagedBy   = "terraform"
  }
}
