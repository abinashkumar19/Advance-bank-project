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

    # GPU node group - exclusively for the self-hosted Ollama chatbot
    # model server (see k8s/services/ollama-deployment.yaml). AL2_x86_64_GPU
    # ships with NVIDIA drivers preinstalled, but Kubernetes still needs
    # the NVIDIA device plugin DaemonSet to actually expose GPUs as an
    # allocatable resource - see helm_release.nvidia_device_plugin below.
    # Tainted so nothing except Ollama (which has the matching toleration)
    # ever gets scheduled here - this instance type costs real money per
    # hour even sitting idle, and nothing else in this app needs a GPU.
    gpu = {
      instance_types = var.gpu_node_instance_types
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2_x86_64_GPU"

      min_size     = var.gpu_node_min_size
      max_size     = var.gpu_node_max_size
      desired_size = var.gpu_node_desired_size

      labels = {
        role = "gpu"
      }

      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
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

# ---------------------------------------------------------------------------
# NVIDIA device plugin - required for Kubernetes to expose the GPU node
# group's GPUs as an allocatable resource (nvidia.com/gpu). The GPU node
# group's AL2_x86_64_GPU AMI ships NVIDIA drivers preinstalled, but that
# alone isn't enough - without this DaemonSet, kubelet has no way to
# advertise the GPU to the scheduler at all, and any pod requesting
# nvidia.com/gpu would just stay Pending forever.
# ---------------------------------------------------------------------------

resource "helm_release" "nvidia_device_plugin" {
  name       = "nvidia-device-plugin"
  repository = "https://nvidia.github.io/k8s-device-plugin"
  chart      = "nvidia-device-plugin"
  namespace  = "kube-system"
  version    = "0.16.2"

  # Only ever run this DaemonSet on the tainted GPU node group - it has
  # nothing to do on the regular app nodes, and the toleration keeps it
  # off nodes it doesn't belong on.
  set {
    name  = "tolerations[0].key"
    value = "nvidia.com/gpu"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "tolerations[0].value"
    value = "true"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }
  set {
    name  = "nodeSelector.role"
    value = "gpu"
  }

  depends_on = [module.eks]
}
