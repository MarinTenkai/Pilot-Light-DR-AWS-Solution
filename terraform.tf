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
      version = ">= 6.30.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.2.1"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.6.2"
    }
  }
}
