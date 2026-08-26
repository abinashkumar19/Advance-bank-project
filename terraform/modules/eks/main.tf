module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = "${var.project_name}-${var.environment}-eks"
  cluster_version = var.eks_cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      labels = {
        role = "app"
      }
    }

    # Dedicated node group - exclusively for the self-hosted Ollama
    # chatbot model server (see k8s/services/ollama-deployment.yaml).
    # This was originally a GPU node group (g4dn.xlarge), but G/VT-family
    # instances require an EC2 service quota that defaults to 0 vCPUs on
    # many AWS accounts, and launching them can also hit IAM/SCP
    # authorization walls that need an account admin to resolve - neither
    # is something Terraform can route around. Standard compute instance
    # families (m6i, c6i, etc.) essentially never run into that, so this
    # trades "GPU-fast" for "no approval process, works today": a
    # dedicated 8-vCPU instance the model doesn't have to share with 30+
    # other pods, which is still a real step up from the shared t3.medium
    # pool even without a GPU. If you resolve the GPU quota/IAM issue
    # later, swap instance_types to a g-series type + set ami_type back to
    # "AL2023_x86_64_NVIDIA" + re-add the NVIDIA device plugin (removed
    # below) + a nvidia.com/gpu resource request in the deployment.
    # Tainted so nothing except Ollama (which has the matching toleration)
    # ever gets scheduled here - this instance costs real money per hour
    # even sitting idle, and nothing else in this app needs this much CPU.
    ollama = {
      instance_types = var.ollama_node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.ollama_node_min_size
      max_size     = var.ollama_node_max_size
      desired_size = var.ollama_node_desired_size

      labels = {
        role = "ollama"
      }

      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "ollama"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# EBS CSI Driver - IRSA role + addon
# ---------------------------------------------------------------------------

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name             = "${var.project_name}-${var.environment}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = module.eks.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [module.eks]
}

# The EBS CSI addon above provisions volumes but does NOT create a default
# StorageClass on its own - nothing in this repo needed persistent storage
# until the self-hosted Ollama model server (everything else is
# DynamoDB/S3, stateless services), so this is the only StorageClass in
# the whole project. gp3 over gp2: cheaper and faster at the same size.
# WaitForFirstConsumer avoids the PVC being bound to a different AZ than
# whichever node the pod actually lands on.
resource "kubernetes_storage_class" "gp3" {
  metadata {
    name = "gp3"
  }
  storage_provisioner = "ebs.csi.aws.com"
  reclaim_policy      = "Delete"
  volume_binding_mode = "WaitForFirstConsumer"
  parameters = {
    type = "gp3"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller - IRSA role + Helm install
# ---------------------------------------------------------------------------

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.44"

  role_name = "${var.project_name}-${var.environment}-alb-controller"

  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn" = module.alb_controller_irsa.iam_role_arn
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.8.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }

  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller.metadata[0].name
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  depends_on = [kubernetes_service_account.alb_controller]
}
