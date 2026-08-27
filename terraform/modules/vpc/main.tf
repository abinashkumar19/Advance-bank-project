# ---------------------------------------------------------------------------
# VPC - creates a new one, UNLESS var.reuse_existing_vpc is explicitly set
# (sandbox/training AWS accounts are often capped at 1 VPC per region, so
# reruns in THAT situation need to reuse whatever's already there instead
# of trying to create a second one).
#
# IMPORTANT: this used to auto-detect "already exists" via a live
# data.aws_vpcs lookup on this same project's VPC tag, and toggle `count`
# off that. That's self-defeating: the very act of successfully creating
# the VPC makes it show up in that lookup, so the NEXT plan (or even a
# later refresh in the same apply) would conclude "this shouldn't exist"
# and try to DESTROY everything under it - the VPC, NAT gateway, subnets,
# with EKS/RDS/OpenSearch all sitting inside them. Explicit var instead:
# the decision never changes just because the module did its job.
# ---------------------------------------------------------------------------

locals {
  vpc_already_exists = var.reuse_existing_vpc
}

data "aws_vpcs" "existing" {
  count = local.vpc_already_exists ? 1 : 0
  tags = {
    Name = "${var.project_name}-${var.environment}-vpc"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  count = local.vpc_already_exists ? 0 : 1

  name = "${var.project_name}-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.eks_cluster_name}" = "shared"
  }
}

data "aws_subnets" "existing_private" {
  count = local.vpc_already_exists ? 1 : 0
  filter {
    name   = "vpc-id"
    values = data.aws_vpcs.existing[0].ids
  }
  tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

data "aws_subnets" "existing_public" {
  count = local.vpc_already_exists ? 1 : 0
  filter {
    name   = "vpc-id"
    values = data.aws_vpcs.existing[0].ids
  }
  tags = {
    "kubernetes.io/role/elb" = "1"
  }
}

# When reusing an existing VPC, look up its private subnets' route tables
# too, so downstream consumers (VPC gateway endpoints) can still attach.
data "aws_route_tables" "existing_private" {
  count  = local.vpc_already_exists ? 1 : 0
  vpc_id = data.aws_vpcs.existing[0].ids[0]
  filter {
    name   = "association.subnet-id"
    values = local.existing_private_subnet_ids_raw
  }
}

locals {
  existing_private_subnet_ids_raw = local.vpc_already_exists ? (
    length(data.aws_subnets.existing_private[0].ids) > 0 ?
    data.aws_subnets.existing_private[0].ids :
    data.aws_subnets.existing_public[0].ids
  ) : []

  vpc_id             = local.vpc_already_exists ? data.aws_vpcs.existing[0].ids[0] : module.vpc[0].vpc_id
  private_subnet_ids = local.vpc_already_exists ? local.existing_private_subnet_ids_raw : module.vpc[0].private_subnets
  public_subnet_ids  = local.vpc_already_exists ? data.aws_subnets.existing_public[0].ids : module.vpc[0].public_subnets

  private_route_table_ids = local.vpc_already_exists ? (
    length(data.aws_route_tables.existing_private) > 0 ? data.aws_route_tables.existing_private[0].ids : []
  ) : module.vpc[0].private_route_table_ids
}
