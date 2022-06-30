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
  version = "~> 3.0"

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
module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws//modules/http-80"
  version = "~> 4.0"

  name        = "${local.name}-alb"
  description = "Security group for web-server with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]

  tags = local.tags
}

resource "aws_lb" "alb" {
  name               = local.name
  load_balancer_type = "application"
  subnets            = module.vpc.public_subnets
  security_groups    = [module.alb_sg.security_group_id]
  idle_timeout       = 60

  tags = local.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Requests otherwise not routed"
      status_code  = "200"
    }
  }
}

## ECS
module "ecs_cluster" {
  source  = "brunordias/ecs-cluster/aws"
  version = "~> 1.0.0"

  name               = local.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy = {
    capacity_provider = "FARGATE"
    weight            = null
    base              = null
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
  lb_listener_arn = [
    aws_lb_listener.http.arn
  ]
  lb_host_header = [aws_lb.alb.dns_name]
  health_check = {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    matcher             = "200"
    path                = "/index.html"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 10
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
