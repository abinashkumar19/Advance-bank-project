output "vpc_id" {
  value = local.vpc_id
}

output "private_subnet_ids" {
  value = local.private_subnet_ids
}

output "public_subnet_ids" {
  value = local.public_subnet_ids
}

output "private_route_table_ids" {
  value = local.private_route_table_ids
}

output "vpc_already_exists" {
  value = local.vpc_already_exists
}
