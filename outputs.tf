output "web_loadbalancer_url" {
  value = aws_lb.nlb.dns_name
}
