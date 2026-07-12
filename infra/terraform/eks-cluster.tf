# ==========================================
# EKS CLUSTER
# ==========================================
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.project_name}-cluster"
  kubernetes_version = "1.31"
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.private_subnets

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  addons = {
    kube-proxy = {}
  }

  self_managed_node_groups = {
    general_nodes = {
      min_size       = 1
      max_size       = 2
      desired_size   = 2
      instance_types = ["t3.medium"]
      platform       = "linux"
      bootstrap_extra_args = "--cni-bin-dir /opt/cni/bin --cni-conf-dir /etc/cni/net.d"
    }
  }

  tags = {
    Environment = "production"
    Project     = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "node_elb" {
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
  role       = module.eks.module.self_managed_node_group["general_nodes"].aws_iam_role.this[0].name
}

# ==========================================
# CALICO PRE-DESTROY
# ==========================================
resource "null_resource" "calico_pre_destroy" {
  triggers = {
    calico_release_id = helm_release.calico.id
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "=== Phase 1: Graceful cleanup ==="
      kubectl delete installation.operator.tigera.io default \
        --wait=true --timeout=90s --ignore-not-found=true 2>/dev/null \
      && echo "=== Operator cleaned up gracefully ===" \
      || echo "=== Timed out, falling through to Phase 2 ==="

      echo "=== Phase 2: Force-clear any remaining finalizers ==="

      kubectl patch installation.operator.tigera.io default \
        --type=json \
        -p='[{"op":"remove","path":"/metadata/finalizers"}]' \
        2>/dev/null || true

      kubectl get pods -n calico-system -o json 2>/dev/null \
        | jq -r '.items[] | select(.metadata.finalizers != null) | .metadata.name' \
        | while read name; do
            kubectl patch pod "$name" -n calico-system \
              --type=json \
              -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
          done

      kubectl get pods -n tigera-operator -o json 2>/dev/null \
        | jq -r '.items[] | select(.metadata.finalizers != null) | .metadata.name' \
        | while read name; do
            kubectl patch pod "$name" -n tigera-operator \
              --type=json \
              -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
          done

      echo "=== Pre-destroy cleanup complete ==="
    EOT
  }

  depends_on = [helm_release.calico]
}

# ==========================================
# CALICO VIA HELM
# ==========================================
resource "helm_release" "calico" {
  name             = "calico"
  repository       = "https://docs.tigera.io/calico/charts"
  chart            = "tigera-operator"
  namespace        = "tigera-operator"
  create_namespace = true
  disable_openapi_validation = true
  version          = "v3.28.0"

  values = [
    <<-EOT
    installation:
      kubernetesProvider: EKS
      cni:
        type: Calico
      calicoNetwork:
        bgp: Disabled
        ipPools:
          - cidr: ${var.calico_cni_cidr}
            encapsulation: VXLAN
    EOT
  ]

  depends_on = [module.eks]
}

# ==========================================
# COREDNS
# ==========================================
resource "aws_eks_addon" "coredns" {
  cluster_name = module.eks.cluster_name
  addon_name   = "coredns"
  depends_on   = [helm_release.calico]
}

# ==========================================
# ARGOCD VIA HELM
# ==========================================
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.3.11"
  depends_on       = [helm_release.calico]
}