provider "aws" {
  region = "eu-central-1"
}

#--------Data------------------------------------------------------------
data "aws_availability_zones" "available" {}

data "aws_ami" "amazon_latest_windows_2019" {
  owners      = ["amazon"]
  most_recent = true
  filter {
    name   = "name"
    values = ["Windows_Server-2019-English-Full-ContainersLatest-*"]
  }
}

resource "aws_default_subnet" "default_az1" {
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_default_subnet" "default_az2" {
  availability_zone = data.aws_availability_zones.available.names[1]
}

#--------GW-Route--------------------------------------------------------

resource "aws_internet_gateway" "maingw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "mainVPC"
  }
}

resource "aws_route_table" "route_table" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.maingw.id
  }

  tags = {
    Name = "main_Route_table"
  }
}

resource "aws_route_table_association" "public_routes" {
  count          = length(aws_subnet.main_subnets[*].id)
  route_table_id = aws_route_table.route_table.id
  subnet_id      = element(aws_subnet.main_subnets[*].id, count.index)
}

#-----------Security Goup------------------------------------------------------
resource "aws_security_group" "http_sg" {
  name   = "Dynamic Security Group for NLB"
  vpc_id = aws_vpc.main.id

  dynamic "ingress" {
    for_each = ["80", "5985"]
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["198.168.1.10/32"] #my_home_ip
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "Dynamic Security Group"
  }
}

#------------------VPC-Sub-----------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags = {
    Name = "mainvpc"
  }
}

resource "aws_subnet" "main_subnets" {
  count                   = length(var.subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = element(var.subnet_cidrs, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "Subnet-${count.index + 1}"
  }
}
#------------------Instance-----------------------------------------------------

resource "aws_instance" "web_server" {
  ami                    = data.amazon_latest_windows_2019.id
  instance_type          = "t2.micro"
  count                  = 2
  vpc_security_group_ids = [aws_security_group.http_sg.id]
  subnet_id              = aws_subnet.main_subnets[count.index].id
  user_data              = file("winrm_service.ps1")

  tags = {
    Name = "WebServer-${count.index + 1}"
  }
}

#------------------Load Balancer--------------------------------------------

resource "aws_lb" "nlb" {
  name                             = "Nloadbalancer"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = aws_subnet.main_subnets.*.id
  enable_cross_zone_load_balancing = true

  tags = {
    name = "Network-load-balancer"
  }
}


resource "aws_lb_listener" "nlb_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = "80"
  protocol          = "TCP"

  depends_on = [aws_lb.nlb, aws_lb_target_group.nlb_targets]

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_targets.arn
  }
}

resource "aws_lb_target_group" "nlb_targets" {
  name     = "NLB-target-group"
  port     = 80
  protocol = "TCP"
  vpc_id   = aws_vpc.main.id

  health_check {
    interval            = 30
    port                = 80
    protocol            = "TCP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "nlb_target_attach" {
  count            = 2
  target_group_arn = aws_lb_target_group.nlb_targets.arn
  target_id        = aws_instance.web_server[count.index].id
  port             = 80
  depends_on       = [aws_lb_target_group.nlb_targets]
}

#--------------------------------------------------
