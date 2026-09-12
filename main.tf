terraform {
  backend "s3" {
    bucket = "sock-shop-terraform-state-161833128386"
    key    = "eks/terraform.tfstate"
    region = "us-east-1"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  availability_zones = slice(
    data.aws_availability_zones.available.names,
    0,
    2
  )
}

# -------------------------
# VPC
# -------------------------

#checkov:skip=CKV2_AWS_12:Default VPC security group will be hardened later
#checkov:skip=CKV2_AWS_11:VPC Flow Logs will be implemented later
resource "aws_vpc" "eks" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# -------------------------
# Internet Gateway
# -------------------------

resource "aws_internet_gateway" "eks" {
  vpc_id = aws_vpc.eks.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

# -------------------------
# Public Subnets
# -------------------------

resource "aws_subnet" "public" {
  count = 2

  vpc_id = aws_vpc.eks.id

  cidr_block = cidrsubnet(
    var.vpc_cidr,
    8,
    count.index
  )

  availability_zone = local.availability_zones[count.index]
  #checkov:skip=CKV_AWS_130:Public subnet intentionally assigns public IPs for internet-facing resources
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.cluster_name}-public-${count.index + 1}"

    "kubernetes.io/role/elb" = "1"
  }
}

# -------------------------
# Private Subnets
# -------------------------

resource "aws_subnet" "private" {
  count = 2

  vpc_id = aws_vpc.eks.id

  cidr_block = cidrsubnet(
    var.vpc_cidr,
    8,
    count.index + 10
  )

  availability_zone = local.availability_zones[count.index]

  tags = {
    Name = "${var.cluster_name}-private-${count.index + 1}"

    "kubernetes.io/role/internal-elb" = "1"

    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# -------------------------
# Public Route Table
# -------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.eks.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id = aws_subnet.public[count.index].id

  route_table_id = aws_route_table.public.id
}

# -------------------------
# NAT Gateway
# -------------------------

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "eks" {
  allocation_id = aws_eip.nat.id

  subnet_id = aws_subnet.public[0].id

  depends_on = [
    aws_internet_gateway.eks
  ]

  tags = {
    Name = "${var.cluster_name}-nat"
  }
}

# -------------------------
# Private Route Table
# -------------------------

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.eks.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks.id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id = aws_subnet.private[count.index].id

  route_table_id = aws_route_table.private.id
}

# -------------------------
# EKS Cluster IAM Role
# -------------------------

resource "aws_iam_role" "eks_cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "eks.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role = aws_iam_role.eks_cluster.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -------------------------
# EKS Cluster
# ------------------------

#checkov:skip=CKV_AWS_58:Secrets encryption with KMS will be implemented later
resource "aws_eks_cluster" "eks" {
  name = var.cluster_name

  role_arn = aws_iam_role.eks_cluster.arn

  version = "1.33"

  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  vpc_config {
    subnet_ids = aws_subnet.private[*].id

    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = {
    Name = var.cluster_name
  }
}
# -------------------------
# Node IAM Role
# -------------------------

resource "aws_iam_role" "eks_nodes" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  role = aws_iam_role.eks_nodes.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  role = aws_iam_role.eks_nodes.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

resource "aws_iam_role_policy_attachment" "cni_policy" {
  role = aws_iam_role.eks_nodes.name

  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}


# -------------------------
# EKS Managed Node Group
# -------------------------

# ============================================================
# CPU EKS Managed Node Group
# ============================================================

resource "aws_eks_node_group" "cpu_nodes" {
  cluster_name = aws_eks_cluster.eks.name

  node_group_name = "${var.cluster_name}-cpu-nodes"

  node_role_arn = aws_iam_role.eks_nodes.arn

  subnet_ids = aws_subnet.private[*].id

  instance_types = [
    var.cpu_node_instance_type
  ]

  # Standard Amazon Linux 2023 EKS AMI
  ami_type = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.cpu_desired_nodes
    min_size     = var.cpu_min_nodes
    max_size     = var.cpu_max_nodes
  }

  capacity_type = "ON_DEMAND"

  labels = {
    workload = "cpu"
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node,
    aws_iam_role_policy_attachment.ecr_read_only,
    aws_iam_role_policy_attachment.cni_policy
  ]

  tags = {
    Name     = "${var.cluster_name}-cpu-worker"
    Workload = "cpu"
  }
}


# ============================================================
# GPU EKS Managed Node Group
# ============================================================

resource "aws_eks_node_group" "gpu_nodes" {
  cluster_name = aws_eks_cluster.eks.name

  node_group_name = "${var.cluster_name}-gpu-nodes"

  node_role_arn = aws_iam_role.eks_nodes.arn

  subnet_ids = aws_subnet.private[*].id

  instance_types = [
    var.gpu_node_instance_type
  ]

  ami_type = "AL2023_x86_64_NVIDIA"

  scaling_config {
    desired_size = var.gpu_desired_nodes
    min_size     = var.gpu_min_nodes
    max_size     = var.gpu_max_nodes
  }

  capacity_type = "ON_DEMAND"
  disk_size = 50


  labels = {
    workload    = "gpu"
    accelerator = "nvidia-t4"
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.worker_node,
    aws_iam_role_policy_attachment.ecr_read_only,
    aws_iam_role_policy_attachment.cni_policy
  ]

  tags = {
    Name     = "${var.cluster_name}-gpu-worker"
    Workload = "gpu"
  }
}
# -------------------------
# EKS Pod Identity Agent
# -------------------------
resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.eks.name

  addon_name = "eks-pod-identity-agent"

  depends_on = [
    aws_eks_node_group.cpu_nodes,
    aws_eks_node_group.gpu_nodes
  ]
}

# -------------------------
# EBS CSI IAM Role
# -------------------------

resource "aws_iam_role" "ebs_csi" {
  name = "${var.cluster_name}-ebs-csi-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "pods.eks.amazonaws.com"
        }

        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role = aws_iam_role.ebs_csi.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# -------------------------
# EBS CSI Addon
# -------------------------

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.eks.name

  addon_name = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi,
    aws_eks_addon.pod_identity
  ]
}

# -------------------------
# VPC CNI
# -------------------------

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.eks.name

  addon_name = "vpc-cni"

  resolve_conflicts_on_create = "OVERWRITE"
}

# -------------------------
# CoreDNS
# -------------------------


resource "aws_eks_addon" "coredns" {

  cluster_name = aws_eks_cluster.eks.name

  addon_name = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.cpu_nodes
  ]
}
# -------------------------
# Kube Proxy
# -------------------------

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.eks.name

  addon_name = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
}