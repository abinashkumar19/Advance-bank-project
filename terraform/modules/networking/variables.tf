variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_already_exists" {
  type = bool
}

variable "private_route_table_ids" {
  type = list(string)
}

variable "app_domain_name" {
  type    = string
  default = ""
}
