output "asg-consul-server-a-name" {
  value = "${aws_autoscaling_group.consul-server-asg-a.name}"
}
output "asg-consul-server-b-name" {
  value = "${aws_autoscaling_group.consul-server-asg-b.name}"
}
output "asg-consul-client" {
  value = "${aws_autoscaling_group.consul-client-asg.name}"
}
