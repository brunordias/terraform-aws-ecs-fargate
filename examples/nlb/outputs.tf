output "nlb_dns_name" {
  value       = aws_lb.nlb.dns_name
  description = "Use this URL to access your ECS NGINX"
}
