### Locals
locals {
  container_definitions = concat([
    {
      cpu              = var.fargate_cpu - try(sum([for c in var.additional_container : (c.cpu)]), 0)
      image            = var.image_uri
      memory           = var.fargate_memory - try(sum([for m in var.additional_container : (m.memory)]), 0)
      name             = var.name
      networkMode      = "awsvpc"
      essential        = var.fargate_essential
      entryPoint       = var.fargate_entrypoint
      command          = var.fargate_command
      user             = var.fargate_user
      workingDirectory = var.fargate_working_directory
      logConfiguration = {
        logDriver = lookup(var.log_configuration, "log_driver", "awslogs")
        options = lookup(var.log_configuration, "log_options", {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "ecs"
        })
        secretOptions = lookup(var.log_configuration, "log_secret_options", null)
      }
      portMappings = [
        {
          containerPort = var.app_port
          hostPort      = var.app_port
        }
      ]
      environmentFiles = var.app_environment_file_arn != null ? [for s in var.app_environment_file_arn : { value = (s), type = "s3" }] : null
      environment      = var.app_environment
      secrets          = var.app_secrets
      mountPoints      = var.efs_mount_configuration
    }
    ],
    [for s in var.additional_container : merge({
      logConfiguration = {
        logDriver = lookup(var.log_configuration, "log_driver", "awslogs")
        options = lookup(var.log_configuration, "log_options", {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "ecs"
        })
        secretOptions = lookup(var.log_configuration, "log_secret_options", null)
      }
    }, s)],
    local.log_router
  )
  log_router = lookup(var.log_configuration, "log_driver", "awslogs") == "awslogs" ? [] : [
    {
      name                  = "log_router"
      image                 = lookup(var.log_configuration, "log_router_image_uri", "amazon/aws-for-fluent-bit:stable")
      essential             = true
      memoryReservation     = lookup(var.log_configuration, "log_router_memory_reservation", 50)
      firelensConfiguration = lookup(var.log_configuration, "firelens_configuration", { type = "fluentbit" })
      user                  = "0"
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = data.aws_region.current.name
          awslogs-stream-prefix = "firelens"
        }
      }
    }
  ]
}

resource "random_id" "suffix" {
  byte_length = 8
}

### Data
data "aws_region" "current" {}

data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_arn" "ecs_cluster" {
  arn = var.ecs_cluster
}

### Security
# Task security group
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.name}-tasks"
  description = "allow inbound access from VPC"
  vpc_id      = data.aws_vpc.this.id

  ingress {
    protocol    = "tcp"
    from_port   = var.app_port
    to_port     = var.app_port
    cidr_blocks = [data.aws_vpc.this.cidr_block]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_security_group_rule" "ecs_tasks" {
  count = length(var.additional_security_group_rules)

  type              = lookup(var.additional_security_group_rules[count.index], "type", "ingress")
  from_port         = var.additional_security_group_rules[count.index].from_port
  to_port           = var.additional_security_group_rules[count.index].to_port
  protocol          = lookup(var.additional_security_group_rules[count.index], "protocol", "tcp")
  cidr_blocks       = lookup(var.additional_security_group_rules[count.index], "cidr_blocks", [data.aws_vpc.this.cidr_block])
  security_group_id = aws_security_group.ecs_tasks.id
}

### ALB
# Target Group
resource "aws_lb_target_group" "app" {
  count = var.load_balancer == true ? 1 : 0

  name        = "${substr(var.name, 0, 29)}-lb"
  port        = var.lb_target_group_port
  protocol    = var.lb_target_group_protocol
  vpc_id      = data.aws_vpc.this.id
  target_type = var.lb_target_group_type

  dynamic "health_check" {
    for_each = var.health_check != null ? [1] : []

    content {
      enabled             = lookup(var.health_check, "enabled", false)
      healthy_threshold   = lookup(var.health_check, "healthy_threshold", null)
      interval            = lookup(var.health_check, "interval", null)
      matcher             = lookup(var.health_check, "matcher", null)
      path                = lookup(var.health_check, "path", null)
      port                = lookup(var.health_check, "port", null)
      protocol            = lookup(var.health_check, "protocol", null)
      timeout             = lookup(var.health_check, "timeout", null)
      unhealthy_threshold = lookup(var.health_check, "unhealthy_threshold", null)
    }
  }

  dynamic "stickiness" {
    for_each = var.lb_stickiness != null ? [1] : []

    content {
      type            = var.lb_stickiness.type
      cookie_duration = var.lb_stickiness.cookie_duration
      enabled         = var.lb_stickiness.enabled
    }
  }

  tags = var.tags
}

# Listener Rule Forward
resource "aws_lb_listener_rule" "forward" {
  count = var.load_balancer == true ? length(var.lb_listener_arn) : 0

  listener_arn = var.lb_listener_arn[count.index]
  priority     = var.lb_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.0.arn
  }

  dynamic "condition" {
    for_each = var.lb_host_header != null ? [1] : []

    content {
      host_header {
        values = var.lb_host_header
      }
    }
  }

  dynamic "condition" {
    for_each = var.lb_path_pattern != null ? [1] : []

    content {
      path_pattern {
        values = var.lb_path_pattern
      }
    }
  }

  tags = var.tags
}

### CloudWatch log group
resource "aws_cloudwatch_log_group" "this" {
  name              = var.cloudwatch_log_group_name != "" ? var.cloudwatch_log_group_name : "/ecs/${var.name}"
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

### Service Discovery
resource "aws_service_discovery_service" "service" {
  count = var.service_discovery == true ? 1 : 0

  name = var.service_discovery_service_name != null ? var.service_discovery_service_name : var.name

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

### ECS
resource "aws_iam_role" "execution_role" {
  name = "${substr(var.name, 0, 32)}-ecs-execution-role-${random_id.suffix.id}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "execution_policy" {
  name = "${substr(var.name, 0, 64)}-ecs-execution-policy-${random_id.suffix.id}"
  role = aws_iam_role.execution_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "s3:GetBucketLocation",
        "s3:PutObject",
        "kms:Decrypt",
        "secretsmanager:GetSecretValue",
        "firehose:PutRecordBatch",
        "kinesis:PutRecords",
        "ssm:GetParameters"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "execution_policy_s3" {
  count = var.app_environment_file_arn != null ? length(var.app_environment_file_arn) : 0

  name = "${substr(var.name, 0, 64)}-ecs-execution-s3-policy-${random_id.suffix.id}-${count.index}"
  role = aws_iam_role.execution_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": [
        "${var.app_environment_file_arn[count.index]}"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role" "task_role" {
  name = "${substr(var.name, 0, 32)}-ecs-task-role-${random_id.suffix.id}"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "ssm_policy" {
  name = "${substr(var.name, 0, 64)}-ecs-ssm-policy-${random_id.suffix.id}"

  policy = <<EOF
{
   "Version": "2012-10-17",
   "Statement": [
       {
       "Effect": "Allow",
       "Action": [
            "ssmmessages:CreateControlChannel",
            "ssmmessages:CreateDataChannel",
            "ssmmessages:OpenControlChannel",
            "ssmmessages:OpenDataChannel"
       ],
      "Resource": "*"
      }
   ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "task_role_ssm" {
  role       = aws_iam_role.task_role.name
  policy_arn = aws_iam_policy.ssm_policy.arn
}

resource "aws_iam_role_policy_attachment" "task_role" {
  count      = length(var.policies)
  role       = aws_iam_role.task_role.name
  policy_arn = var.policies[count.index]
}

data "aws_ecs_task_definition" "app" {
  task_definition = aws_ecs_task_definition.app.family
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.execution_role.arn
  task_role_arn            = aws_iam_role.task_role.arn
  skip_destroy             = var.task_definition_skip_destroy

  dynamic "volume" {
    for_each = var.efs_volume_configuration

    content {
      name = volume.value.name

      efs_volume_configuration {
        file_system_id          = volume.value.file_system_id
        root_directory          = try(volume.value.root_directory, "/")
        transit_encryption      = try(volume.value.transit_encryption, "DISABLED")
        transit_encryption_port = try(volume.value.transit_encryption_port, null)

        dynamic "authorization_config" {
          for_each = try(volume.value.authorization_config_access_point_id, null) != null ? [1] : []

          content {
            access_point_id = volume.value.authorization_config_access_point_id
            iam             = try(volume.value.volume.authorization_config_iam, "DISABLED")
          }
        }
      }
    }
  }

  container_definitions = var.container_definitions != null ? jsonencode(var.container_definitions) : jsonencode(local.container_definitions)

  dynamic "runtime_platform" {
    for_each = var.operating_system_family != "LINUX" || var.cpu_architecture != "X86_64" ? [1] : []

    content {
      operating_system_family = var.operating_system_family
      cpu_architecture        = var.cpu_architecture
    }
  }

  dynamic "ephemeral_storage" {
    for_each = var.ephemeral_storage != 21 ? [1] : []

    content {
      size_in_gib = var.ephemeral_storage
    }
  }

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  count = var.ecs_service == true ? 1 : 0

  name                              = "${var.name}-service"
  cluster                           = var.ecs_cluster
  task_definition                   = data.aws_ecs_task_definition.app.arn
  desired_count                     = var.ecs_service_desired_count
  launch_type                       = var.capacity_provider_strategy == null ? "FARGATE" : null
  propagate_tags                    = "SERVICE"
  platform_version                  = var.platform_version
  enable_execute_command            = true
  health_check_grace_period_seconds = var.load_balancer == true ? var.health_check_grace_period_seconds : null

  dynamic "deployment_circuit_breaker" {
    for_each = var.deployment_circuit_breaker == true ? [1] : []

    content {
      enable   = true
      rollback = true
    }
  }

  network_configuration {
    security_groups  = concat([aws_security_group.ecs_tasks.id], var.additional_security_group_ids)
    subnets          = var.subnet_ids
    assign_public_ip = var.assign_public_ip
  }

  deployment_controller {
    type = var.deployment_controller
  }

  dynamic "load_balancer" {
    for_each = var.load_balancer == true ? [1] : []

    content {
      target_group_arn = aws_lb_target_group.app.0.id
      container_name   = var.name
      container_port   = var.app_port
    }
  }

  dynamic "service_registries" {
    for_each = var.service_discovery == true ? [1] : []

    content {
      registry_arn = aws_service_discovery_service.service.0.arn
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy != null ? var.capacity_provider_strategy : []

    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = lookup(capacity_provider_strategy.value, "weight", null)
      base              = lookup(capacity_provider_strategy.value, "base", null)
    }
  }

  depends_on = [
    aws_lb_listener_rule.forward,
    aws_security_group.ecs_tasks
  ]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = var.tags
}

## ECS Service Autoscaling
resource "aws_appautoscaling_target" "ecs_target" {
  count = var.autoscaling == true ? 1 : 0

  max_capacity       = lookup(var.autoscaling_settings, "max_capacity", 1)
  min_capacity       = lookup(var.autoscaling_settings, "min_capacity", 1)
  resource_id        = "service/${trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")}/${aws_ecs_service.this.0.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy_cpu" {
  count = var.autoscaling == true && lookup(var.autoscaling_settings, "target_cpu_value", 0) != 0 ? 1 : 0

  name               = "${var.name}-scale-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.0.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.0.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.0.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value       = lookup(var.autoscaling_settings, "target_cpu_value", 0)
    scale_in_cooldown  = var.autoscaling_settings.scale_in_cooldown
    scale_out_cooldown = var.autoscaling_settings.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_memory" {
  count = var.autoscaling == true && lookup(var.autoscaling_settings, "target_memory_value", 0) != 0 ? 1 : 0

  name               = "${var.name}-scale-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.0.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.0.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.0.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value       = lookup(var.autoscaling_settings, "target_memory_value", 0)
    scale_in_cooldown  = var.autoscaling_settings.scale_in_cooldown
    scale_out_cooldown = var.autoscaling_settings.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_requests" {
  count = var.autoscaling == true && lookup(var.autoscaling_settings, "target_request_value", 0) != 0 ? 1 : 0

  name               = "${var.name}-scale-request"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.0.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.0.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.0.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.lb_arn_suffix}/${aws_lb_target_group.app.0.arn_suffix}"
    }

    target_value       = lookup(var.autoscaling_settings, "target_request_value", 0)
    scale_in_cooldown  = var.autoscaling_settings.scale_in_cooldown
    scale_out_cooldown = var.autoscaling_settings.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_custom" {
  count = var.autoscaling == true && lookup(var.autoscaling_settings, "custom_metric", [""]) != [""] ? length(var.autoscaling_settings.custom_metric) : 0

  name               = "${var.name}-scale-custom-metric-${count.index}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.0.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.0.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.0.service_namespace

  target_tracking_scaling_policy_configuration {
    customized_metric_specification {
      metric_name = var.autoscaling_settings.custom_metric[count.index].metric_name
      namespace   = var.autoscaling_settings.custom_metric[count.index].namespace
      statistic   = try(var.autoscaling_settings.custom_metric[count.index].statistic, "Average")
      unit        = try(var.autoscaling_settings.custom_metric[count.index].unit, null)


      dynamic "dimensions" {
        for_each = try(var.autoscaling_settings.custom_metric[count.index].dimensions, [])

        content {
          name  = dimensions.value.name
          value = dimensions.value.value

        }
      }
    }

    target_value       = var.autoscaling_settings.custom_metric[count.index].target_value
    scale_in_cooldown  = var.autoscaling_settings.scale_in_cooldown
    scale_out_cooldown = var.autoscaling_settings.scale_out_cooldown
  }
}

resource "aws_appautoscaling_policy" "ecs_policy_response_time" {
  count = var.autoscaling == true && lookup(var.autoscaling_settings, "target_response_time", 0) != 0 ? 1 : 0

  name               = "${var.name}-scale-response-time"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.0.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.0.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.0.service_namespace

  target_tracking_scaling_policy_configuration {
    customized_metric_specification {
      metric_name = "TargetResponseTime"
      namespace   = "AWS/ApplicationELB"
      statistic   = "Average"
      unit        = null

      dimensions {
        name  = "LoadBalancer"
        value = var.lb_arn_suffix
      }
      dimensions {
        name  = "TargetGroup"
        value = aws_lb_target_group.app.0.arn_suffix
      }
    }

    target_value       = lookup(var.autoscaling_settings, "target_response_time", 0)
    scale_in_cooldown  = var.autoscaling_settings.scale_in_cooldown
    scale_out_cooldown = var.autoscaling_settings.scale_out_cooldown
  }
}

resource "aws_appautoscaling_scheduled_action" "ecs_scheduled" {
  count = var.autoscaling == true && lookup(var.autoscaling_settings, "scheduled", [""]) != [""] ? length(var.autoscaling_settings.scheduled) : 0

  name               = "${var.name}-scale-scheduled-${count.index}"
  resource_id        = aws_appautoscaling_target.ecs_target.0.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.0.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.0.service_namespace
  schedule           = var.autoscaling_settings.scheduled[count.index].schedule
  start_time         = try(var.autoscaling_settings.scheduled[count.index].start_time, null)
  end_time           = try(var.autoscaling_settings.scheduled[count.index].end_time, null)
  timezone           = try(var.autoscaling_settings.scheduled[count.index].timezone, "UTC")

  scalable_target_action {
    min_capacity = try(var.autoscaling_settings.scheduled[count.index].min_capacity, null)
    max_capacity = try(var.autoscaling_settings.scheduled[count.index].max_capacity, null)
  }
}

## CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "ecs_service_cpu" {
  count = lookup(var.cloudwatch_settings, "enabled", false) == true && lookup(var.cloudwatch_settings, "cpu_threshold", false) != false ? 1 : 0

  alarm_name          = "${var.cloudwatch_settings.prefix}-ECS-${trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")}/${aws_ecs_service.this.0.name}->High-CPU-Utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  threshold           = var.cloudwatch_settings.cpu_threshold

  metric_query {
    id          = "m0r0"
    return_data = false

    metric {
      dimensions = {
        "ClusterName" = trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")
        "ServiceName" = aws_ecs_service.this.0.name
      }
      metric_name = "CpuUtilized"
      namespace   = "ECS/ContainerInsights"
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id          = "m0r1"
    return_data = false

    metric {
      dimensions = {
        "ClusterName" = trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")
        "ServiceName" = aws_ecs_service.this.0.name
      }
      metric_name = "CpuReserved"
      namespace   = "ECS/ContainerInsights"
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    expression  = "m0r0 * 100 / m0r1"
    id          = "e0"
    label       = aws_ecs_service.this.0.name
    return_data = true
  }

  alarm_actions = var.cloudwatch_settings.sns_topic_arn
  ok_actions    = var.cloudwatch_settings.sns_topic_arn

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_service_memory" {
  count = lookup(var.cloudwatch_settings, "enabled", false) == true && lookup(var.cloudwatch_settings, "memory_threshold", false) != false ? 1 : 0

  alarm_name          = "${var.cloudwatch_settings.prefix}-ECS-${trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")}/${aws_ecs_service.this.0.name}->High-Memory-Utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "1"
  threshold           = var.cloudwatch_settings.memory_threshold

  metric_query {
    id          = "m0r0"
    return_data = false

    metric {
      dimensions = {
        "ClusterName" = trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")
        "ServiceName" = aws_ecs_service.this.0.name
      }
      metric_name = "MemoryUtilized"
      namespace   = "ECS/ContainerInsights"
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id          = "m0r1"
    return_data = false

    metric {
      dimensions = {
        "ClusterName" = trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")
        "ServiceName" = aws_ecs_service.this.0.name
      }
      metric_name = "MemoryReserved"
      namespace   = "ECS/ContainerInsights"
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    expression  = "m0r0 * 100 / m0r1"
    id          = "e0"
    label       = aws_ecs_service.this.0.name
    return_data = true
  }

  alarm_actions = var.cloudwatch_settings.sns_topic_arn
  ok_actions    = var.cloudwatch_settings.sns_topic_arn

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_service_max_task_count" {
  count = lookup(var.cloudwatch_settings, "enabled", false) == true && lookup(var.cloudwatch_settings, "max_task_count", false) != false ? 1 : 0

  alarm_name          = "${var.cloudwatch_settings.prefix}-ECS-${trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")}/${aws_ecs_service.this.0.name}->High-Task-Count"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = "300"
  statistic           = "Average"
  threshold           = var.cloudwatch_settings.max_task_count

  dimensions = {
    ClusterName = trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")
    ServiceName = aws_ecs_service.this.0.name
  }

  alarm_actions = var.cloudwatch_settings.sns_topic_arn
  ok_actions    = var.cloudwatch_settings.sns_topic_arn

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_service_min_task_count" {
  count = lookup(var.cloudwatch_settings, "enabled", false) == true && lookup(var.cloudwatch_settings, "min_task_count", false) != false ? 1 : 0

  alarm_name          = "${var.cloudwatch_settings.prefix}-ECS-${trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")}/${aws_ecs_service.this.0.name}->Low-Task-Count"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "1"
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = "300"
  statistic           = "Average"
  threshold           = var.cloudwatch_settings.min_task_count

  dimensions = {
    ClusterName = trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")
    ServiceName = aws_ecs_service.this.0.name
  }

  alarm_actions = var.cloudwatch_settings.sns_topic_arn
  ok_actions    = var.cloudwatch_settings.sns_topic_arn

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_service_deployment_count" {
  count = lookup(var.cloudwatch_settings, "enabled", false) == true && lookup(var.cloudwatch_settings, "deployment_count", false) != false ? 1 : 0

  alarm_name          = "${var.cloudwatch_settings.prefix}-ECS-${trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")}/${aws_ecs_service.this.0.name}->Deployment-Count"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "DeploymentCount"
  namespace           = "ECS/ContainerInsights"
  period              = "300"
  statistic           = "Average"
  threshold           = var.cloudwatch_settings.deployment_count

  dimensions = {
    ClusterName = trimprefix(data.aws_arn.ecs_cluster.resource, "cluster/")
    ServiceName = aws_ecs_service.this.0.name
  }

  alarm_actions = var.cloudwatch_settings.sns_topic_arn
  ok_actions    = var.cloudwatch_settings.sns_topic_arn

  tags = var.tags
}
