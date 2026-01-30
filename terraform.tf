terraform {
  required_version = ">= 1.14.3"

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "marin-tenkai"
    workspaces {
      name = "devops-aws-pldr-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 3.1.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.1.0"
    }
  }
}
