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
    vpc-cni = {
      # CRITICAL for self-managed groups: initialises network before nodes boot
      before_compute    = true
      most_recent       = true
      
      # Optional optimization configurations can go inside configuration_values
      configuration_values = jsonencode({
        env = {
          # Recommended configuration: Warms up IP addresses for quicker pod spin-ups
          WARM_IP_TARGET = "5" 
        }
      })
    }
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

# ==========================================
# COMPLETELY OPEN SECURITY GROUP RULES FOR WORKER NODES
# ==========================================

# 1. Allow all Inbound TCP Traffic from anywhere
resource "aws_security_group_rule" "nodes_allow_all_tcp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks.node_security_group_id
}

# 2. Allow all Inbound UDP Traffic from anywhere
resource "aws_security_group_rule" "nodes_allow_all_udp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks.node_security_group_id
}

# 3. Allow all Inbound ICMP (Ping/Diagnostics) from anywhere
resource "aws_security_group_rule" "nodes_allow_all_icmp" {
  type              = "ingress"
  from_port         = -1
  to_port           = -1
  protocol          = "icmp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.eks.node_security_group_id
}

resource "aws_iam_role_policy_attachment" "node_elb" {
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
  role       = module.eks.self_managed_node_groups["general_nodes"].iam_role_name
  depends_on = [module.eks]
}

# IRSA role for AWS Load Balancer Controller
resource "aws_iam_role" "albc" {
  name = "aws-load-balancer-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_policy" "albc" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/albc-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "albc" {
  policy_arn = aws_iam_policy.albc.arn
  role       = aws_iam_role.albc.name
  depends_on = [aws_iam_role.albc]
}

# ==========================================
# COREDNS
# ==========================================
resource "aws_eks_addon" "coredns" {
  cluster_name = module.eks.cluster_name
  addon_name   = "coredns"
  depends_on   = [module.eks]
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
  depends_on       = [module.eks, aws_eks_addon.coredns]

  # Pass configuration as a clean YAML block instead of a 'set' block
  values = [
    <<-EOT
    configs:
      params:
        server.insecure: "true"
    EOT
  ]
}

resource "kubernetes_manifest" "argocd_aws_load_balancer_controller" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"

    metadata = {
      name       = "aws-load-balancer-controller"
      namespace  = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }

    spec = {
      project = "default"

      source = {
        repoURL        = "https://aws.github.io/eks-charts"
        chart          = "aws-load-balancer-controller"
        targetRevision = "1.8.1"

        helm = {
          # Multi-line YAML string leveraging dynamic Terraform interpolation strings
          values = <<-EOT
            clusterName: ${module.eks.cluster_name}
            serviceAccount:
              create: true
              name: aws-load-balancer-controller
              annotations:
                eks.amazonaws.com/role-arn: ${aws_iam_role.albc.arn}
            region: us-east-1
            vpcId: ${module.vpc.vpc_id}
            enableCertManager: false
            enableServiceMutatorWebhook: false
            backendSecurityGroup: ""
          EOT
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "kube-system"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }

  depends_on = [module.eks, helm_release.argocd]
}

resource "kubernetes_manifest" "argocd_nginx_ingress_application" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    
    metadata = {
      name      = "nginx-ingress"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io"
      ]
    }

    spec = {
      project = "default"
      
      source = {
        repoURL        = "https://kubernetes.github.io/ingress-nginx"
        chart          = "ingress-nginx"
        targetRevision = "4.10.1"
        
        helm = {
          # Using YAML multi-line string notation inside HCL to match your original values exactly
          values = <<-EOT
            controller:
              service:
                type: NodePort
              admissionWebhooks:
                enabled: false
          EOT
        }
      }

      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "ingress-nginx"
      }

      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }

  depends_on = [kubernetes_manifest.argocd_aws_load_balancer_controller]
}

resource "kubernetes_ingress_v1" "edge_alb_ingress" {
  metadata {
    name      = "edge-alb-ingress"
    namespace = "ingress-nginx"

    annotations = {
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      # Force the ALB to target EC2 NodePorts rather than direct Pod IPs
      "alb.ingress.kubernetes.io/target-type"      = "instance"
      # Match the default health check endpoint exposed by NGINX
      "alb.ingress.kubernetes.io/healthcheck-path" = "/healthz"
    }
  }

  spec {
    ingress_class_name = "alb" # Triggers the AWS Load Balancer Controller

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "nginx-ingress-ingress-nginx-controller"

              port {
                number = 80 # ALB maps port 80 to NGINX's assigned HTTP NodePort
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.argocd_nginx_ingress_application]
}

resource "kubernetes_ingress_v1" "ecommerce_app_ingress_argocd_ns" {
  metadata {
    name      = "ecommerce-app-ingress-argocd-ns"
    namespace = "argocd"

    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect"       = "false"
      "nginx.ingress.kubernetes.io/force-ssl-redirect" = "false"
      # Securely routes traffic using TLS to the backend Argo pods
      "nginx.ingress.kubernetes.io/backend-protocol"   = "HTTP"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = "ecommerce-app-argocd-himanshu1234.duckdns.org"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "argocd-server"

              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [module.eks, helm_release.argocd, kubernetes_manifest.argocd_aws_load_balancer_controller, 
    kubernetes_manifest.argocd_nginx_ingress_application
  ]
}


# ==========================================
# ARGOCD SERVER NODEPORT SERVICE
# ==========================================
resource "kubernetes_service_v1" "argocd_server_nodeport" {
  metadata {
    name      = "argocd-server-nodeport"
    namespace = "argocd"
  }

  spec {
    type = "NodePort"

    selector = {
      "app.kubernetes.io/name" = "argocd-server"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      node_port   = 30080
    }

    port {
      name        = "https"
      port        = 443
      target_port = 8080
      node_port   = 30443
    }
  }
}

# ==========================================
# ARGOCD SERVER CLUSTERIP SERVICE
# ==========================================
resource "kubernetes_service_v1" "argocd_server_clusterip" {
  metadata {
    name      = "argocd-server-clusterip"
    namespace = "argocd"
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "argocd-server"
    }

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}