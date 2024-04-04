# AWS ECS Fargate Terraform module
Terraform module which provides tasks definitions, services, scaling and load balancing to ECS powered by AWS Fargate.

## Usage

```hcl
## Locals
locals {
  tags = {
    environment = "development"
  }
}

## Data
data "aws_lb" "this" {
  name = "my-alb"
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.this.arn
  port              = 443
}

data "aws_lb_listener" "http" {
  load_balancer_arn = data.aws_lb.this.arn
  port              = 80
}

## ECS Cluster
module "ecs_cluster" {
  source             = "brunordias/ecs-cluster/aws"
  version            = "~> 2.0.0"

  name               = "terraform-ecs-test"
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
  default_capacity_provider_strategy = {
    capacity_provider = "FARGATE_SPOT"
    weight            = 5
    base              = 1
  }
  container_insights = "enabled"
  
  tags = local.tags
}

## ECS Fargate
module "ecs_fargate" {
  source  = "brunordias/ecs-fargate/aws"
  version = "~> 8.0.0"

  name                       = "nginx"
  ecs_cluster                = module.ecs_cluster.id
  image_uri                  = "public.ecr.aws/nginx/nginx:1.19-alpine"
  platform_version           = "1.4.0"
  vpc_id                     = "vpc-example"
  subnet_ids                 = ["subnet-example001", "subnet-example002"]
  fargate_cpu                = 256
  fargate_memory             = 512
  ecs_service_desired_count  = 2
  app_port                   = 80
  load_balancer              = true
  ecs_service                = true
  cpu_architecture           = "X86_64"
  deployment_circuit_breaker = true
  policies = [
    "arn:aws:iam::aws:policy/example"
  ]
  lb_listener_arn = [
    data.aws_lb_listener.https.arn,
    data.aws_lb_listener.http.arn
  ]
  lb_path_pattern = [
    "/v1"
  ]
  lb_host_header = ["app.example.com"]
  lb_priority    = 101
  lb_arn_suffix  = aws_lb.this.arn_suffix
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
      capacity_provider = "FARGATE"
      weight            = 1
      base              = 0
    },
    {
      capacity_provider = "FARGATE_SPOT"
      weight            = 4
      base              = 0
    }
  ]
  autoscaling = true
  autoscaling_settings  = {
    max_capacity         = 10
    min_capacity         = 1
    target_cpu_value     = 65
    target_memory_value  = 65
    target_response_time = 2
    scale_in_cooldown    = 300
    scale_out_cooldown   = 300
    custom_metric = [
      {
        target_value = 100
        metric_name  = "ApproximateNumberOfMessagesVisible"
        namespace    = "AWS/SQS"
        statistic    = "Average"
        unit         = "Count"
        dimensions = [
          {
            name  = "QueueName"
            value = "your-queue-name"
          }
        ]
      }
    ]
    scheduled = [
      {
        schedule     = "cron(00 7 * * ? *)"
        min_capacity = 5
        max_capacity = 10
        timezone     = "America/Sao_Paulo"
      },
      {
        schedule     = "cron(30 20 * * ? *)"
        min_capacity = 1
        max_capacity = 1
        timezone     = "America/Sao_Paulo"
      }
    ]
  }
  cloudwatch_settings = {
    enabled          = true
    prefix           = "example"
    cpu_threshold    = 80
    memory_threshold = 80
    max_task_count   = 4
    min_task_count   = 1
    deployment_count = 1
    sns_topic_arn    = ["arn:aws:sns:us-east-1:1111111111:NotifyMe"]
  }
  app_environment = [
    {
      name  = "ENV-NAME"
      value = "development"
    }
  ]
  app_environment_file_arn = [
    "arn:aws:s3:::bucket-example/file.env"
  ]
  app_secrets = [
    {
      name      = "ENV-NAME"
      valueFrom = "arn:aws:secretsmanager:us-east-1:000000000:secret:example/ENV-NAME-id"
    }
  ]
  efs_volume_configuration = [
    {
      name                                 = "efs-example"
      file_system_id                       = "fs-xxxxxx"
      root_directory                       = "/"
      transit_encryption                   = null
      transit_encryption_port              = null
      authorization_config_access_point_id = null
      authorization_config_iam             = null
    }
  ]
  efs_mount_configuration = [
    {
      sourceVolume = "efs-example"
      containerPath = "/mount"
      readOnly = false
    }
  ]

  tags = local.tags
}
```
## Aditional Container
To create aditional container in task definition, use `aditional_container` input.

Use the [Task Definition Parameters](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html)
```
additional_container = [
  {
    name      = "datadog-agent"
    image     = "public.ecr.aws/datadog/agent:latest"
    cpu       = 256
    memory    = 512
    essential = true
    environment = [
      {
        name  = "DD_API_KEY"
        value = "<YOUR_API_KEY>"
      },
      {
        name  = "ECS_FARGATE"
        value = "true"
      }
    ]
  }
]
```

## Log Configuration
To use Firelens as log router, use `log_configuration` input.
```
log_configuration = {
  log_driver = "awsfirelens"
  log_options = {
    Name            = "S3"
    region          = "us-east-1"
    bucket          = "your-bucket"
    total_file_size = "1M"
    upload_timeout  = "1m"
    use_put_object  = "On"
    retry_limit     = "2"
  }
  firelens_configuration = {
    type = "fluentbit"
  }
  log_router_image_uri = "amazon/aws-for-fluent-bit:stable"
}
```

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 0.13.1 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 3.74.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.4.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 3.74.0 |
| <a name="provider_random"></a> [random](#provider\_random) | >= 3.4.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_appautoscaling_policy.ecs_policy_cpu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.ecs_policy_custom](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.ecs_policy_memory](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.ecs_policy_requests](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_policy.ecs_policy_response_time](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy) | resource |
| [aws_appautoscaling_scheduled_action.ecs_scheduled](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_scheduled_action) | resource |
| [aws_appautoscaling_target.ecs_target](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_target) | resource |
| [aws_cloudwatch_log_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.ecs_service_cpu](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.ecs_service_deployment_count](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.ecs_service_max_task_count](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.ecs_service_memory](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.ecs_service_min_task_count](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_ecs_service.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_policy.ssm_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.execution_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.task_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.execution_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.execution_policy_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.task_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.task_role_ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lb_listener_rule.forward](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener_rule) | resource |
| [aws_lb_target_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_security_group.ecs_tasks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.ecs_tasks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_service_discovery_service.service](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_service) | resource |
| [random_id.suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) | resource |
| [aws_arn.ecs_cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/arn) | data source |
| [aws_ecs_task_definition.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecs_task_definition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_additional_container"></a> [additional\_container](#input\_additional\_container) | List of additional ECS Task containers. | `list(any)` | `[]` | no |
| <a name="input_additional_security_group_ids"></a> [additional\_security\_group\_ids](#input\_additional\_security\_group\_ids) | List of additional ECS Service Security Group IDs. | `list(any)` | `[]` | no |
| <a name="input_additional_security_group_rules"></a> [additional\_security\_group\_rules](#input\_additional\_security\_group\_rules) | List of additional rules to be added in the ECS Service Security Group. | `list(any)` | `[]` | no |
| <a name="input_app_environment"></a> [app\_environment](#input\_app\_environment) | List of one or more environment variables to be inserted in the container. | `list(any)` | `[]` | no |
| <a name="input_app_environment_file_arn"></a> [app\_environment\_file\_arn](#input\_app\_environment\_file\_arn) | The ARN from the environment file hosted in S3. | `list(any)` | `null` | no |
| <a name="input_app_port"></a> [app\_port](#input\_app\_port) | The application TCP port number. | `number` | n/a | yes |
| <a name="input_app_secrets"></a> [app\_secrets](#input\_app\_secrets) | List of one or more environment variables from Secrets Manager. | `list(any)` | `[]` | no |
| <a name="input_assign_public_ip"></a> [assign\_public\_ip](#input\_assign\_public\_ip) | Assign a public IP address to the ENI | `bool` | `true` | no |
| <a name="input_autoscaling"></a> [autoscaling](#input\_autoscaling) | Boolean designating an Auto Scaling. | `bool` | `false` | no |
| <a name="input_autoscaling_settings"></a> [autoscaling\_settings](#input\_autoscaling\_settings) | Settings of Auto Scaling. | `any` | <pre>{<br>  "max_capacity": 0,<br>  "min_capacity": 0,<br>  "scale_in_cooldown": 300,<br>  "scale_out_cooldown": 300,<br>  "target_cpu_value": 0<br>}</pre> | no |
| <a name="input_capacity_provider_strategy"></a> [capacity\_provider\_strategy](#input\_capacity\_provider\_strategy) | The capacity provider strategy to use for the service. | `list(any)` | `null` | no |
| <a name="input_cloudwatch_log_group_name"></a> [cloudwatch\_log\_group\_name](#input\_cloudwatch\_log\_group\_name) | The name of an existing CloudWatch group. | `string` | `""` | no |
| <a name="input_cloudwatch_settings"></a> [cloudwatch\_settings](#input\_cloudwatch\_settings) | Settings of Cloudwatch Alarms. | `any` | `{}` | no |
| <a name="input_container_definitions"></a> [container\_definitions](#input\_container\_definitions) | External ECS container definitions | `any` | `null` | no |
| <a name="input_cpu_architecture"></a> [cpu\_architecture](#input\_cpu\_architecture) | The CPU architecture. Valid values: X86\_64 or ARM64. | `string` | `"X86_64"` | no |
| <a name="input_deployment_circuit_breaker"></a> [deployment\_circuit\_breaker](#input\_deployment\_circuit\_breaker) | Boolean designating a deployment circuit breaker. | `bool` | `false` | no |
| <a name="input_deployment_controller"></a> [deployment\_controller](#input\_deployment\_controller) | Type of deployment controller. Valid values: CODE\_DEPLOY, ECS, EXTERNAL | `string` | `"ECS"` | no |
| <a name="input_ecs_cluster"></a> [ecs\_cluster](#input\_ecs\_cluster) | The ARN of ECS cluster. | `string` | `""` | no |
| <a name="input_ecs_service"></a> [ecs\_service](#input\_ecs\_service) | Boolean designating a service. | `bool` | `false` | no |
| <a name="input_ecs_service_desired_count"></a> [ecs\_service\_desired\_count](#input\_ecs\_service\_desired\_count) | The number of instances of the task definition to place and keep running. | `number` | `1` | no |
| <a name="input_efs_mount_configuration"></a> [efs\_mount\_configuration](#input\_efs\_mount\_configuration) | Settings of EFS mount configuration. | `list(any)` | `[]` | no |
| <a name="input_efs_volume_configuration"></a> [efs\_volume\_configuration](#input\_efs\_volume\_configuration) | Settings of EFS volume configuration. | `list(any)` | `[]` | no |
| <a name="input_ephemeral_storage"></a> [ephemeral\_storage](#input\_ephemeral\_storage) | The total amount, in GiB, of ephemeral storage to set for the task. The minimum supported value is 21 GiB and the maximum supported value is 200 GiB. | `number` | `21` | no |
| <a name="input_fargate_command"></a> [fargate\_command](#input\_fargate\_command) | The command that's passed to the container. This parameter maps to Cmd in the Create a container. | `list(any)` | `null` | no |
| <a name="input_fargate_cpu"></a> [fargate\_cpu](#input\_fargate\_cpu) | Fargate instance CPU units to provision (1 vCPU = 1024 CPU units). | `number` | `256` | no |
| <a name="input_fargate_entrypoint"></a> [fargate\_entrypoint](#input\_fargate\_entrypoint) | The entry point that's passed to the container. This parameter maps to Entrypoint in the Create a container. | `list(any)` | `null` | no |
| <a name="input_fargate_essential"></a> [fargate\_essential](#input\_fargate\_essential) | Boolean designating a Fargate essential container. | `bool` | `true` | no |
| <a name="input_fargate_memory"></a> [fargate\_memory](#input\_fargate\_memory) | Fargate instance memory to provision (in MiB). | `number` | `512` | no |
| <a name="input_fargate_user"></a> [fargate\_user](#input\_fargate\_user) | The user to use inside the container. | `string` | `null` | no |
| <a name="input_fargate_working_directory"></a> [fargate\_working\_directory](#input\_fargate\_working\_directory) | The working directory to run commands inside the container in. This parameter maps to WorkingDir in the Create a container. | `string` | `null` | no |
| <a name="input_health_check"></a> [health\_check](#input\_health\_check) | Health check in Load Balance target group. | `map(any)` | `null` | no |
| <a name="input_health_check_grace_period_seconds"></a> [health\_check\_grace\_period\_seconds](#input\_health\_check\_grace\_period\_seconds) | The period of time, in seconds, that the Amazon ECS service scheduler should ignore unhealthy Elastic Load Balancing target health checks after a task has first started. | `number` | `0` | no |
| <a name="input_image_uri"></a> [image\_uri](#input\_image\_uri) | The container image URI. | `string` | n/a | yes |
| <a name="input_lb_arn_suffix"></a> [lb\_arn\_suffix](#input\_lb\_arn\_suffix) | The ARN suffix for use with Auto Scaling ALB requests per target and resquet response time. | `string` | `""` | no |
| <a name="input_lb_host_header"></a> [lb\_host\_header](#input\_lb\_host\_header) | List of host header patterns to match. | `list(any)` | `null` | no |
| <a name="input_lb_listener_arn"></a> [lb\_listener\_arn](#input\_lb\_listener\_arn) | List of ARN LB listeners | `list(any)` | `[]` | no |
| <a name="input_lb_path_pattern"></a> [lb\_path\_pattern](#input\_lb\_path\_pattern) | List of path patterns to match. | `list(any)` | `null` | no |
| <a name="input_lb_priority"></a> [lb\_priority](#input\_lb\_priority) | The priority for the rule between 1 and 50000. | `number` | `null` | no |
| <a name="input_lb_stickiness"></a> [lb\_stickiness](#input\_lb\_stickiness) | LB Stickiness block. | `map(any)` | `null` | no |
| <a name="input_lb_target_group_port"></a> [lb\_target\_group\_port](#input\_lb\_target\_group\_port) | The port on which targets receive traffic, unless overridden when registering a specific target. | `number` | `80` | no |
| <a name="input_lb_target_group_protocol"></a> [lb\_target\_group\_protocol](#input\_lb\_target\_group\_protocol) | The protocol to use for routing traffic to the targets. Should be one of TCP, TLS, UDP, TCP\_UDP, HTTP or HTTPS. | `string` | `"HTTP"` | no |
| <a name="input_lb_target_group_type"></a> [lb\_target\_group\_type](#input\_lb\_target\_group\_type) | The type of target that you must specify when registering targets with this target group. | `string` | `"ip"` | no |
| <a name="input_load_balancer"></a> [load\_balancer](#input\_load\_balancer) | Boolean designating a load balancer. | `bool` | `false` | no |
| <a name="input_log_configuration"></a> [log\_configuration](#input\_log\_configuration) | Settings of Custom log routing. | `any` | `{}` | no |
| <a name="input_log_retention_in_days"></a> [log\_retention\_in\_days](#input\_log\_retention\_in\_days) | The number of days to retain log in CloudWatch. | `number` | `7` | no |
| <a name="input_name"></a> [name](#input\_name) | Used to name resources and prefixes. | `string` | n/a | yes |
| <a name="input_operating_system_family"></a> [operating\_system\_family](#input\_operating\_system\_family) | The operating system family in the runtime platform setting. | `string` | `"LINUX"` | no |
| <a name="input_platform_version"></a> [platform\_version](#input\_platform\_version) | The Fargate platform version on which to run your service. | `string` | `"LATEST"` | no |
| <a name="input_policies"></a> [policies](#input\_policies) | List of one or more IAM policy ARN to be used in the Task execution IAM role. | `list(any)` | `[]` | no |
| <a name="input_service_discovery"></a> [service\_discovery](#input\_service\_discovery) | Boolean designating a Service Discovery Namespace. | `bool` | `false` | no |
| <a name="input_service_discovery_namespace_id"></a> [service\_discovery\_namespace\_id](#input\_service\_discovery\_namespace\_id) | Service Discovery Namespace ID. | `string` | `null` | no |
| <a name="input_service_discovery_service_name"></a> [service\_discovery\_service\_name](#input\_service\_discovery\_service\_name) | The name of the Service Discovery. | `string` | `null` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | List of one or more subnet ids where the task will be performed. | `list(any)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | A mapping of tags to assign to all resources. | `map(string)` | `{}` | no |
| <a name="input_task_definition_skip_destroy"></a> [task\_definition\_skip\_destroy](#input\_task\_definition\_skip\_destroy) | Whether to retain the old revision of the task definition when the resource is destroyed or replacement is necessary. | `bool` | `false` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | The VPC id where the task will be performed. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_task_definition_arn"></a> [task\_definition\_arn](#output\_task\_definition\_arn) | The ARN of the task definition. |
| <a name="output_task_lb_target_group_arn"></a> [task\_lb\_target\_group\_arn](#output\_task\_lb\_target\_group\_arn) | The ARN of the task load balancer target group. |
| <a name="output_task_security_group_id"></a> [task\_security\_group\_id](#output\_task\_security\_group\_id) | The id of the Security Group used in tasks. |

## Authors

Module managed by [Bruno Dias](https://github.com/brunordias).

## License

Apache 2 Licensed. See LICENSE for full details.