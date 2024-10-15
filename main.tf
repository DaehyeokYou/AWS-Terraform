provider "aws" {
  region = "ap-northeast-2"
}

data "aws_availability_zones" "available" {}

locals {
  cluster_name = "terraform-eks-cluster"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name                 = "terraform-eks-vpc"
  cidr                 = "10.0.0.0/16"
  azs                  = ["ap-northeast-2a", "ap-northeast-2c"]
  private_subnets      = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets       = ["10.0.4.0/24", "10.0.5.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.28"
  subnet_ids      = module.vpc.private_subnets
  vpc_id = module.vpc.vpc_id

  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    instance_types = ["t3.xlarge"]
  }

  eks_managed_node_groups = {
    one = {
      name = "terraform-node-group-1"

      instance_types = ["t3.xlarge"]

      min_size     = 1
      max_size     = 3
      desired_size = 2

      vpc_security_group_ids = [aws_security_group.terraform_all_worker_mgmt.id]
    }
  }

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false
}

# Auto Scaling 그룹 데이터 소스
data "aws_autoscaling_groups" "eks_nodes" {
  filter {
    name   = "tag:eks:cluster-name"
    values = [local.cluster_name]
  }

  depends_on = [module.eks]
}

# 평일 오전 9시 스케줄 (노드 수 증가)
resource "aws_autoscaling_schedule" "scale_up" {
  count                  = length(data.aws_autoscaling_groups.eks_nodes.names)
  scheduled_action_name  = "scale_up"
  min_size               = 2
  max_size               = 2
  desired_capacity       = 2
  recurrence             = "0 9 * * MON-FRI"
  time_zone              = "Asia/Seoul"
  autoscaling_group_name = data.aws_autoscaling_groups.eks_nodes.names[count.index]
}

# 평일 오후 8시 스케줄 (노드 수 감소)
resource "aws_autoscaling_schedule" "scale_down" {
  count                  = length(data.aws_autoscaling_groups.eks_nodes.names)
  scheduled_action_name  = "scale_down"
  min_size               = 0
  max_size               = 2
  desired_capacity       = 0
  recurrence             = "0 20 * * MON-FRI"
  time_zone              = "Asia/Seoul"
  autoscaling_group_name = data.aws_autoscaling_groups.eks_nodes.names[count.index]
}

resource "aws_security_group" "terraform_all_worker_mgmt" {
  name_prefix = "terraform_all_worker_management"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/8",
    ]
  }
}

# Bastion Host
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "terraform_bastion" {
  ami           = data.aws_ami.amazon_linux_2.id # "ami-0c55b159cbfafe1f0"  # Amazon Linux 2 AMI (HVM), SSD Volume Type
  instance_type = "t2.micro"
  key_name      = "terraform-key-pair"  # Make sure to create or import this key pair in AWS

  vpc_security_group_ids = [aws_security_group.terraform_bastion.id]
  subnet_id              = module.vpc.public_subnets[0]

  tags = {
    Name = "terraform-EKS-Bastion"
  }
}

resource "aws_security_group" "terraform_bastion" {
  name        = "terraform-bastion"
  description = "Allow SSH inbound traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # 보안을 위해 특정 IP로 제한하는 것이 좋습니다
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "terraform-allow-ssh"
  }
}
