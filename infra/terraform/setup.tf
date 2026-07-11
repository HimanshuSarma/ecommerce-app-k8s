terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket = "himanshutest-123-622047409214-us-east-1-an"
    key = "ecommerce-app/terraform.tfstate"
    region = "us-east-1"

    dynamodb_table = "ecommerce-app"
  }
}

provider "aws" {
  region = var.aws_region
}

provider "helm" {
  # Helm v3 requires the equals sign here because 'kubernetes' is now a map attribute!
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}