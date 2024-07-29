provider "aws" {
  region = local.region
}

locals {
  name   = "nginx-example"
  region = "us-east-1"
  tags = {
    Environment = "dev"
  }
}

################################################################################
# Supporting Resources
################################################################################

## VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = "172.29.0.0/16"

  azs             = ["${local.region}a", "${local.region}b", "${local.region}c"]
  public_subnets  = ["172.29.0.0/24", "172.29.1.0/24", "172.29.2.0/24"]
  private_subnets = ["172.29.3.0/24", "172.29.4.0/24", "172.29.5.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.tags
}

## ALB
resource "aws_lb" "nlb" {
  name               = local.name
  load_balancer_type = "network"
  subnets            = module.vpc.public_subnets

  tags = local.tags
}

resource "aws_lb_listener" "tcp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = "80"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = module.ecs_fargate.task_lb_target_group_arn
  }
}

## ECS
module "ecs_cluster" {
  source  = "brunordias/ecs-cluster/aws"
  version = "~> 2.0.0"

  name               = local.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy = {
    capacity_provider = "FARGATE"
  }
  container_insights = "disabled"

  tags = local.tags
}

################################################################################
# ECS Fargate Module
################################################################################

module "ecs_fargate" {
  source = "../../"

  name                       = local.name
  ecs_cluster                = module.ecs_cluster.id
  image_uri                  = "public.ecr.aws/nginx/nginx:1.19-alpine"
  platform_version           = "1.4.0"
  vpc_id                     = module.vpc.vpc_id
  subnet_ids                 = module.vpc.private_subnets
  fargate_cpu                = 256
  fargate_memory             = 512
  ecs_service_desired_count  = 1
  app_port                   = 80
  load_balancer              = true
  ecs_service                = true
  deployment_circuit_breaker = true
  lb_target_group_protocol   = "TCP"
  health_check = {
    enabled  = true
    interval = 30
    port     = "traffic-port"
    protocol = "TCP"
  }
  capacity_provider_strategy = [
    {
      capacity_provider = "FARGATE_SPOT"
      weight            = 100
      base              = 0
    }
  ]
  autoscaling = false
  app_environment = [
    {
      name  = "ENV-NAME"
      value = "development"
    }
  ]

  tags = local.tags
}
