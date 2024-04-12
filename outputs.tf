output "jenkins_service_available_here" {
  value = aws_iam_role.ecs_task_execution_role.arn
}
