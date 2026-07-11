# Input Variables
# AWS Region
variable "aws_region" {
  description = "Region in which AWS Resources to be created"
  type = string
  default = "us-east-1"  
}

variable "vpc_name" {
  description = "VPC name"
  type = string
  default = "ecommerce_app"
}

variable "project_name" {
  description = "Project Name"
  type = string
  default = "ecommerce_app"
}

variable "vpc_cidr_block" {
  description = "VPC CIDR block"
  type = string
  default = "10.0.0.0/16"
}

variable "vpc_public_subnets" {
  description = "VPC Public Subnets"
  type = list(string)
  # default = ["10.0.101.0/24", "10.0.102.0/24"]
  default = ["10.0.0.0/24", "10.0.2.0/24"]
}

variable "vpc_private_subnets" {
  description = "VPC Private Subnets"
  type = list(string)
  # default = ["10.0.101.0/24", "10.0.102.0/24"]
  default = ["10.0.1.0/24", "10.0.3.0/24"]
}

variable "calico_cni_cidr" {
  description = "Calico CNI CIDR Range"
  type = string
  # default = ["10.0.101.0/24", "10.0.102.0/24"]
  default = "192.168.0.0/16"
}

variable "vpc_create_database_subnet_group" {
  description = "Should we have a db subnet group or not"
  type = bool
  default = false
}

variable "vpc_create_database_subnet_route_table" {
  description = "Should we have a db subnet route table or not"
  type = bool
  default = false
}

variable "vpc_enable_nat_gateway" {
  description = "Enable a NAT gateway or not"
  type = bool
  default = true
}

variable "vpc_single_nat_gateway" {
  description = "Do we need a single NAT?"
  type = bool
  default = true
}