terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # TODO: configure remote state backend (e.g. S3 + DynamoDB lock table)
  # backend "s3" {
  #   bucket         = ""
  #   key            = "terraform.tfstate"
  #   region         = ""
  #   dynamodb_table = ""
  # }
}

provider "aws" {
  region = var.aws_region
}
