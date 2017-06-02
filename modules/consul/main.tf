# AWS Keypair for SSH
resource "aws_key_pair" "auth" {
  key_name   = "${var.key_name}"
  public_key = "${file(var.public_key_path)}"
}

// AMIs by region for AWS Optimised Linux
data "aws_ami" "amazonlinux" {
  most_recent = true

  owners = ["137112412989"]

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "name"
    values = ["amzn-ami-hvm-*"]
  }
}

data "template_file" "consul_server" {
  template = "${file("${path.module}/files/consul-server.sh")}"

  vars {
    region                          = "${var.region}"
    consul_server_count_expected    = "${var.consul_server_count}"
    subnet_a                        = "${aws_subnet.backend-a.id}"
    subnet_b                        = "${aws_subnet.backend-b.id}"
    nomad_subnet_a                  = "${aws_subnet.bastion-a.id}"
    nomad_subnet_b                  = "${aws_subnet.bastion-b.id}"
  }
}

data "template_file" "consul_client" {
  template = "${file("${path.module}/files/consul-client.sh")}"

  vars {
    region                          = "${var.region}"
    consul_server_count_expected    = "${var.consul_server_count}"
    subnet_a                        = "${aws_subnet.backend-a.id}"
    subnet_b                        = "${aws_subnet.backend-b.id}"
    nomad_subnet_a                  = "${aws_subnet.bastion-a.id}"
    nomad_subnet_b                  = "${aws_subnet.bastion-b.id}"
  }
}

// @FIXME
data "template_file" "nomad_server" {
  template = "${file("${path.module}/files/nomad-server.sh")}"

  vars {
    region                          = "${var.region}"
    consul_server_count_expected    = "${var.consul_server_count}"
    subnet_a                        = "${aws_subnet.backend-a.id}"
    subnet_b                        = "${aws_subnet.backend-b.id}"
    nomad_subnet_a                  = "${aws_subnet.bastion-a.id}"
    nomad_subnet_b                  = "${aws_subnet.bastion-b.id}"
  }
}

//  Launch configuration for the consul cluster auto-scaling group.
resource "aws_launch_configuration" "consul-cluster-server-lc" {
  name_prefix          = "consul-server-"
  image_id             = "${data.aws_ami.amazonlinux.image_id}"
  instance_type        = "${var.amisize}"
  user_data            = "${data.template_file.consul_server.rendered}"
  iam_instance_profile = "${aws_iam_instance_profile.consul-instance-profile.id}"

  security_groups = [
    "${aws_security_group.consul-cluster-vpc.id}",
    "${aws_security_group.consul-cluster-public-web.id}",
    "${aws_security_group.consul-cluster-public-ssh.id}",
  ]

  lifecycle {
    create_before_destroy = true
  }

  key_name = "${var.key_name}"
}

//  Launch configuration for the consul cluster auto-scaling group.
resource "aws_launch_configuration" "consul-cluster-client-lc" {
  name_prefix          = "consul-client-"
  image_id             = "${data.aws_ami.amazonlinux.image_id}"
  instance_type        = "${var.amisize}"
  user_data            = "${data.template_file.consul_client.rendered}"
  iam_instance_profile = "${aws_iam_instance_profile.consul-instance-profile.id}"

  security_groups = [
    "${aws_security_group.consul-cluster-vpc.id}",
    "${aws_security_group.consul-cluster-public-web.id}",
    "${aws_security_group.consul-cluster-public-ssh.id}",
  ]

  lifecycle {
    create_before_destroy = true
  }

  key_name = "${var.key_name}"
}

//  Launch configuration for the consul cluster auto-scaling group.
resource "aws_launch_configuration" "nomad-cluster-server-lc" {
  name_prefix          = "nomad-server-"
  image_id             = "${data.aws_ami.amazonlinux.image_id}"
  instance_type        = "${var.amisize}"
  user_data            = "${data.template_file.nomad_server.rendered}"
  iam_instance_profile = "${aws_iam_instance_profile.consul-instance-profile.id}"

  security_groups = [
    "${aws_security_group.consul-cluster-vpc.id}",
    "${aws_security_group.consul-cluster-public-web.id}",
    "${aws_security_group.consul-cluster-public-ssh.id}",
  ]

  lifecycle {
    create_before_destroy = true
  }

  key_name = "${var.key_name}"
}

//  Load balancers for our consul cluster.
/*
resource "aws_elb" "consul-lb" {
  name = "consul-lb"

  security_groups = [
    "${aws_security_group.consul-cluster-vpc.id}",
    "${aws_security_group.consul-cluster-public-web.id}",
  ]

  subnets = ["${aws_subnet.public-a.id}", "${aws_subnet.public-b.id}"]

  listener {
    instance_port     = 8500
    instance_protocol = "http"
    lb_port           = 8500
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    target              = "HTTP:8500/ui/"
    interval            = 30
  }
}
*/

//  Auto-scaling group for our cluster (zone a).
resource "aws_autoscaling_group" "consul-server-asg-a" {
  depends_on           = ["aws_launch_configuration.consul-cluster-server-lc", "aws_cloudwatch_log_group.consul-cluster-docker-log-group"]
  name                 = "${var.asg_consul_server_name}-a"
  launch_configuration = "${aws_launch_configuration.consul-cluster-server-lc.name}"
  min_size             = "${var.consul_server_count}"
  max_size             = "${var.consul_server_count}"
  vpc_zone_identifier  = ["${aws_subnet.backend-a.id}"]
  // load_balancers       = ["${aws_elb.consul-lb.name}"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "Consul Node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "consul-cluster"
    propagate_at_launch = true
  }

  tag {
    key                 = "Consul-Role"
    value               = "server"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "consul-server-asg-b" {
  depends_on           = ["aws_launch_configuration.consul-cluster-server-lc", "aws_cloudwatch_log_group.consul-cluster-docker-log-group"]
  name                 = "${var.asg_consul_server_name}-b"
  launch_configuration = "${aws_launch_configuration.consul-cluster-server-lc.name}"
  min_size             = "${var.consul_server_count}"
  max_size             = "${var.consul_server_count}"
  vpc_zone_identifier  = ["${aws_subnet.backend-b.id}"]
  // load_balancers       = ["${aws_elb.consul-lb.name}"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "Consul Node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "consul-cluster"
    propagate_at_launch = true
  }

  tag {
    key                 = "Consul-Role"
    value               = "server"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "consul-client-asg" {
  depends_on           = ["aws_launch_configuration.consul-cluster-client-lc", "aws_cloudwatch_log_group.consul-cluster-docker-log-group"]
  name                 = "${var.asg_consul_client_name}"
  launch_configuration = "${aws_launch_configuration.consul-cluster-client-lc.name}"
  min_size             = "${var.min_size}"
  max_size             = "${var.max_size}"
  vpc_zone_identifier  = ["${aws_subnet.backend-a.id}", "${aws_subnet.backend-b.id}"]
  // load_balancers       = ["${aws_elb.consul-lb.name}"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "Consul Node"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "consul-cluster"
    propagate_at_launch = true
  }

  tag {
    key                 = "Consul-Role"
    value               = "client"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group" "nomad-server-asg" {
  depends_on           = ["aws_launch_configuration.nomad-cluster-server-lc", "aws_cloudwatch_log_group.consul-cluster-docker-log-group"]
  name                 = "nomad-server-asg"
  launch_configuration = "${aws_launch_configuration.nomad-cluster-server-lc.name}"
  min_size             = "${var.nomad_server_count}"
  max_size             = "${var.nomad_server_count}"
  vpc_zone_identifier  = ["${aws_subnet.bastion-a.id}", "${aws_subnet.bastion-b.id}"]
  // load_balancers       = ["${aws_elb.consul-lb.name}"]

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "Bastion"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = "consul-cluster"
    propagate_at_launch = true
  }

  tag {
    key                 = "Nomad-Role"
    value               = "server"
    propagate_at_launch = true
  }
}

// Cloudwatch log group for Docker app logs
resource "aws_cloudwatch_log_group" "consul-cluster-docker-log-group" {
  name = "/var/log/docker-container"

  tags {
    Environment = "Project"
    Application = "consul-cluster"
  }
}
