resource "aws_vpc" "vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
}

resource "aws_internet_gateway" "lab4_igw" {
  vpc_id = aws_vpc.vpc.id
}

resource "aws_route" "route_to_igw" {
  route_table_id         = aws_vpc.vpc.default_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.lab4_igw.id
}

resource "aws_security_group" "lab4_jenk_sg" {
  name        = "lab4-jenkins-security-group"
  description = "Security group for lab4"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "all_traffic_inbound" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1" # All protocols
  security_group_id        = aws_security_group.lab4_jenk_sg.id
  source_security_group_id = aws_security_group.lab4_jenk_sg.id
}

resource "aws_subnet" "subnet_1" {
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-east-1d"
  #   availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "EcsTaskExecutionRoleLab4"
  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",

    "Statement" : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "Service" : "ecs-tasks.amazonaws.com"
        },
        "Action" : "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "task_execution_policy" {
  name = "task-execution-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_policy_attachment" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = aws_iam_policy.task_execution_policy.arn
}

resource "aws_ecr_repository" "lab4_ecr" {
  name                 = "lab4-ecr"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
}

resource "null_resource" "build_and_push_image" {
  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOT
      docker tag jenkins:${var.image_tag} ${var.account_id}.dkr.ecr.${var.region}.amazonaws.com/${aws_ecr_repository.lab4_ecr.name}:latest
      aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${var.account_id}.dkr.ecr.${var.region}.amazonaws.com
      docker push ${var.account_id}.dkr.ecr.${var.region}.amazonaws.com/${aws_ecr_repository.lab4_ecr.name}:latest
    EOT
  }
  depends_on = [aws_ecr_repository.lab4_ecr]
}

resource "aws_ecs_cluster" "lab4_ecs_cluster" {
  name = "lab4-ecs-cluster"
}

resource "aws_ecs_task_definition" "lab4_task" {
  family                   = "lab4-task"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "lab4-jenkins-container"
      image     = "${aws_ecr_repository.lab4_ecr.repository_url}:latest"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "jenkins_service" {
  name                    = "jenkins-service"
  cluster                 = aws_ecs_cluster.lab4_ecs_cluster.id
  task_definition         = aws_ecs_task_definition.lab4_task.arn
  desired_count           = 1
  launch_type             = "FARGATE"
  enable_ecs_managed_tags = true
  wait_for_steady_state   = true #important!!! to get public ip later for DNS record

  network_configuration {
    subnets          = [aws_subnet.subnet_1.id]
    security_groups  = [aws_security_group.lab4_jenk_sg.id]
    assign_public_ip = true
  }

  depends_on = [null_resource.build_and_push_image, aws_iam_role_policy_attachment.task_execution_policy_attachment]
}

data "aws_network_interfaces" "service_network_interface" {
  depends_on = [aws_ecs_service.jenkins_service]
  tags = {
    "aws:ecs:serviceName" = aws_ecs_service.jenkins_service.name
  }
}

data "aws_network_interface" "eni-ip" {
  depends_on = [aws_ecs_service.jenkins_service]
  id         = data.aws_network_interfaces.service_network_interface.ids[0]
}

resource "aws_route53_record" "ecs_task_dns" {
  zone_id = var.dns_hosted_zone_id
  name    = var.dns_service_name
  type    = "A"
  ttl     = 300
  records = [data.aws_network_interface.eni-ip.association[0].public_ip]
}

output "service-url" {
  value       = "http://${var.dns_service_name}:8080"
  sensitive   = false
  description = "Jenkins is running here: "
}
