variable "region" {
  description = "The region to deploy the cluster in, e.g: us-east-1."
}

variable "amisize" {
  description = "The size of the cluster nodes, e.g: t2.micro"
}

variable "min_size" {
  description = "The minimum size of the cluter, e.g. 5"
}

variable "max_size" {
  description = "The maximum size of the cluter, e.g. 5"
}

variable "consul_server_count" {
  description = "The number of the consul servers, e.g. 3"
}

variable "nomad_server_count" {
  description = "The number of the nomad servers, e.g. 3"
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC, e.g: 10.0.0.0/16"
}

variable "subnetaz1" {
  description = "The AZ for the first public subnet, e.g: us-east-1a"
  type = "map"
}

variable "subnetaz2" {
  description = "The AZ for the second public subnet, e.g: us-east-1b"
  type = "map"
}

variable "subnet_backend_cidr1" {
  description = "The CIDR block for the first backend subnet, e.g: 10.0.2.0/25"
}

variable "subnet_backend_cidr2" {
  description = "The CIDR block for the second backend subnet, e.g: 10.0.2.1/25"
}

variable "subnet_bastion_cidr1" {
  description = "The CIDR block for the first bastion subnet, e.g: 10.0.2.0/25"
}

variable "subnet_bastion_cidr2" {
  description = "The CIDR block for the second bastion subnet, e.g: 10.0.2.1/25"
}

variable "key_name" {
  description = "The name of the key to user for ssh access, e.g: consul-cluster"
}

variable "public_key_path" {
  description = "The local public key path, e.g. ~/.ssh/id_rsa.pub"
}

variable "asg_consul_server_name" {
  description = "The consul-server auto-scaling group name, e.g: consul-server-asg"
}

variable "asg_consul_client_name" {
  description = "The consul-client auto-scaling group name, e.g: consul-client-asg"
}
