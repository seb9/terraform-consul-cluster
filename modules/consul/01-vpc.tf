//  Define the VPC.
resource "aws_vpc" "consul-cluster" {
  cidr_block           = "${var.vpc_cidr}" // i.e. 10.0.0.0 to 10.0.255.255
  enable_dns_hostnames = true

  tags {
    Name    = "Consul Cluster VPC"
    Project = "consul-cluster"
  }
}

//  Create an Internet Gateway for the VPC.
resource "aws_internet_gateway" "consul-cluster" {
  vpc_id = "${aws_vpc.consul-cluster.id}"

  tags {
    Name    = "Consul Cluster IGW"
    Project = "consul-cluster"
  }
}

//  Create a backend subnet for each AZ.
resource "aws_subnet" "backend-a" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "${var.subnet_backend_cidr1}"                       // i.e. 10.0.1.0 to 10.0.1.255
  availability_zone       = "${lookup(var.subnetaz1, var.region)}"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]

  tags {
    Name    = "Consul Cluster Backend Subnet"
    Project = "consul-cluster"
  }
}

resource "aws_subnet" "backend-b" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "${var.subnet_backend_cidr2}"                       // i.e. 10.0.2.0 to 10.0.1.255
  availability_zone       = "${lookup(var.subnetaz2, var.region)}"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]

  tags {
    Name    = "Consul Cluster Backend Subnet"
    Project = "consul-cluster"
  }
}

//  Create a bastion subnet for each AZ.
resource "aws_subnet" "bastion-a" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "${var.subnet_bastion_cidr1}"                       // i.e. 10.0.1.0 to 10.0.1.255
  availability_zone       = "${lookup(var.subnetaz1, var.region)}"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]

  tags {
    Name    = "Consul Cluster Bastion Subnet"
    Project = "consul-cluster"
  }
}

resource "aws_subnet" "bastion-b" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "${var.subnet_bastion_cidr2}"                       // i.e. 10.0.2.0 to 10.0.1.255
  availability_zone       = "${lookup(var.subnetaz2, var.region)}"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]

  tags {
    Name    = "Consul Cluster Bastion Subnet"
    Project = "consul-cluster"
  }
}

/*
//  Create a frontend subnet for each AZ.
resource "aws_subnet" "frontend-a" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "${var.subnet_frontend_cidr1}"                       // i.e. 10.0.1.0 to 10.0.1.255
  availability_zone       = "${lookup(var.subnetaz1, var.region)}"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]

  tags {
    Name    = "Consul Cluster Public Subnet"
    Project = "consul-cluster"
  }
}

resource "aws_subnet" "frontend-b" {
  vpc_id                  = "${aws_vpc.consul-cluster.id}"
  cidr_block              = "${var.subnet_frontend_cidr2}"                       // i.e. 10.0.2.0 to 10.0.1.255
  availability_zone       = "${lookup(var.subnetaz2, var.region)}"
  map_public_ip_on_launch = true
  depends_on              = ["aws_internet_gateway.consul-cluster"]

  tags {
    Name    = "Consul Cluster Public Subnet"
    Project = "consul-cluster"
  }
}
*/
//  Create a route table allowing all addresses access to the IGW.
resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.consul-cluster.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.consul-cluster.id}"
  }

  tags {
    Name    = "Consul Cluster Public Route Table"
    Project = "consul-cluster"
  }
}

//  Now associate the route table with the public subnet - giving
//  all backend subnet instances access to the internet.
resource "aws_route_table_association" "backend-a" {
  subnet_id      = "${aws_subnet.backend-a.id}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table_association" "backend-b" {
  subnet_id      = "${aws_subnet.backend-b.id}"
  route_table_id = "${aws_route_table.public.id}"
}

//  Now associate the route table with the public subnet - giving
//  all bastions subnet instances access to the internet.
resource "aws_route_table_association" "bastion-a" {
  subnet_id      = "${aws_subnet.bastion-a.id}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table_association" "bastion-b" {
  subnet_id      = "${aws_subnet.bastion-b.id}"
  route_table_id = "${aws_route_table.public.id}"
}

/*
//  Now associate the route table with the public subnet - giving
//  all frontend subnet instances access to the internet.
resource "aws_route_table_association" "frontend-a" {
  subnet_id      = "${aws_subnet.frontend-a.id}"
  route_table_id = "${aws_route_table.public.id}"
}

resource "aws_route_table_association" "frontend-b" {
  subnet_id      = "${aws_subnet.frontend-b.id}"
  route_table_id = "${aws_route_table.public.id}"
}
*/

//  Create an internal security group for the VPC, which allows everything in the VPC
//  to talk to everything else.
resource "aws_security_group" "consul-cluster-vpc" {
  name        = "consul-cluster-vpc"
  description = "Default security group that allows inbound and outbound traffic from all instances in the VPC"
  vpc_id      = "${aws_vpc.consul-cluster.id}"

  ingress {
    from_port = "0"
    to_port   = "0"
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port = "0"
    to_port   = "0"
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = "80"
    to_port     = "80"
    protocol    = "6"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = "443"
    to_port     = "443"
    protocol    = "6"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "Consul Cluster Internal VPC"
    Project = "consul-cluster"
  }
}

//  Create a security group allowing web access to the public subnet.
resource "aws_security_group" "consul-cluster-public-web" {
  name        = "consul-cluster-public-web"
  description = "Security group that allows web traffic from internet"
  vpc_id      = "${aws_vpc.consul-cluster.id}"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  //  The Consul admin UI is exposed over 8500...
  ingress {
    from_port   = 8500
    to_port     = 8500
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "Consul Cluster Public Web"
    Project = "consul-cluster"
  }
}

//  Create a security group which allows ssh access from the web.
//  Remember: This is *not* secure for production! In production, use a Bastion.
resource "aws_security_group" "consul-cluster-public-ssh" {
  name        = "consul-cluster-public-ssh"
  description = "Security group that allows SSH traffic from internet"
  vpc_id      = "${aws_vpc.consul-cluster.id}"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name    = "Consul Cluster Public SSH"
    Project = "consul-cluster"
  }
}
