provider "aws" {
  alias  = "primary"
  region = var.primary_region
  default_tags {
    tags = {
      Environment = terraform.workspace
      Owner       = "marin.tenkai"
      Project     = var.project_name
      terraform   = "true"
      RegionRole  = "Primary"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region
  default_tags {
    tags = {
      Environment = terraform.workspace
      Owner       = "marin.tenkai"
      Project     = var.project_name
      terraform   = "true"
      RegionRole  = "Secondary"
    }
  }
}

# Route53 HealthCheck metrics están en CloudWatch us-east-1 (N. Virginia)
provider "aws" {
  alias  = "sns"
  region = "us-east-1"
}
