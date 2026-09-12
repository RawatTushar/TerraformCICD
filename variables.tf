variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sock-shop-eks"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}



# -------------------------
# CPU Node Group
# -------------------------

variable "cpu_node_instance_type" {
  description = "EC2 instance type for CPU worker nodes"
  type        = string
  default     = "c5.xlarge"
}

variable "cpu_desired_nodes" {
  type    = number
  default = 1
}

variable "cpu_min_nodes" {
  type    = number
  default = 1
}

variable "cpu_max_nodes" {
  type    = number
  default = 2
}


# -------------------------
# GPU Node Group
# -------------------------

variable "gpu_node_instance_type" {
  description = "EC2 instance type for GPU worker nodes"
  type        = string
  default     = "g4dn.xlarge"
}

variable "gpu_desired_nodes" {
  type    = number
  default = 1
}

variable "gpu_min_nodes" {
  type    = number
  default = 1
}

variable "gpu_max_nodes" {
  type    = number
  default = 1
}