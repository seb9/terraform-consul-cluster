#!/bin/bash

# Log everything we do.
set -x
exec > /var/log/user-data.log 2>&1

# A few variables we will refer to later...
REGION="${region}"
CONSUL_SERVER_COUNT_EXPECTED="${consul_server_count_expected}"
IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
MAC_ADDR=$(ifconfig eth0 | grep -Eo [:0-9A-F:]{2}\(\:[:0-9A-F:]{2}\){5} |  tr '[:upper:]' '[:lower:]')
SUBNET_ID=$(curl http://169.254.169.254/latest/meta-data/network/interfaces/macs/$MAC_ADDR/subnet-id)
AZ=$(curl http://169.254.169.254/latest/meta-data/placement/availability-zone)
SUBNET_A_ID="${subnet_a}"
SUBNET_B_ID="${subnet_b}"
NOMAD_SUBNET_A_ID="${nomad_subnet_a}"
NOMAD_SUBNET_B_ID="${nomad_subnet_b}"

# Sets the "other" Subnet
[[ $SUBNET_ID = $SUBNET_A_ID ]] && OTHER_SUBNET="$SUBNET_B_ID" || OTHER_SUBNET="$SUBNET_A_ID"


# Install consul and init script
adduser --system --no-create-home consul
curl -so /etc/init.d/consul https://gist.githubusercontent.com/sybeck2k/f948ab0f52e089735b410fcefa0bb3e2/raw/4692a0280867a7c408bc4bd1d62129cb108b9d94/gistfile1.sh && chmod +x /etc/init.d/consul
curl -so consul.zip https://releases.hashicorp.com/consul/0.8.3/consul_0.8.3_linux_amd64.zip?_ga=2.129474444.1253846471.1496136091-795717082.1477556337 && unzip consul.zip && mv consul /usr/local/sbin/ && rm consul.zip
mkdir -p {/opt/consul,/etc/consul.d}
chown consul:consul /opt/consul/
# Allow consul to bind to lower ports (DNS)
setcap 'cap_net_bind_service=+ep' /usr/local/sbin/consul

# Install nomad and init script
curl -so /etc/init.d/nomad https://gist.githubusercontent.com/sybeck2k/1f8bf89a488cfcd9796c4d6e41b8bb75/raw/34719b19254abc02e2a9806a7fc245256942b3bd/nomad && chmod +x /etc/init.d/nomad
curl -so nomad.zip https://releases.hashicorp.com/nomad/0.5.6/nomad_0.5.6_linux_amd64.zip?_ga=2.226815704.450980263.1496326972-1740804836.1489764259 && unzip nomad.zip && mv nomad /usr/local/sbin/ && rm nomad.zip
mkdir -p {/opt/nomad,/etc/nomad.d}

# Update the packages, install CloudWatch tools.
yum update -y
yum install -y awslogs jq docker

# Create a config file for awslogs to push logs to the same region of the cluster.
cat <<- EOF | sudo tee /etc/awslogs/awscli.conf
  [plugins]
  cwlogs = cwlogs
  [default]
  region = ${region}
EOF

# Create a config file for awslogs to log our user-data log.
cat <<- EOF | sudo tee /etc/awslogs/config/user-data.conf
  [/var/log/user-data.log]
  file = /var/log/user-data.log
  log_group_name = /var/log/user-data.log
  log_stream_name = $INSTANCE_ID
EOF

# Create a config file for awslogs to log our docker log.
cat <<- EOF | sudo tee /etc/awslogs/config/docker.conf
  [/var/log/docker]
  file = /var/log/docker
  log_group_name = /var/log/docker
  log_stream_name = $INSTANCE_ID
  datetime_format = %Y-%m-%dT%H:%M:%S.%f
EOF

# Create a config file for awslogs to log our docker log.
cat <<- EOF | sudo tee /etc/awslogs/config/consul.conf
  [/var/log/consul]
  file = /var/log/consul
  log_group_name = /var/log/consul
  log_stream_name = $INSTANCE_ID
  datetime_format = %Y-%m-%dT%H:%M:%S.%f
EOF

# seems an issue to start awslogs too early...let's wait
sleep 2

# Start the awslogs service, also start on reboot.
# Note: Errors go to /var/log/awslogs.log
service awslogs start
chkconfig awslogs on

# Install Docker, add ec2-user, start Docker and ensure startup on restart
usermod -a -G docker ec2-user

# Set AWS CloudWatch as Docker default log driver
cat <<- EOF | sudo tee /etc/sysconfig/docker
DAEMON_MAXFILES=1048576
OPTIONS="--default-ulimit nofile=1024:4096 --log-driver=awslogs --log-opt awslogs-region=${region} --log-opt awslogs-group=/var/log/docker-container"
EOF

# Return the IP of each running consul server in the same AZ as mine.
function cluster-instance-ips {
    aws --region="$REGION" ec2 describe-instances --filters "Name=network-interface.subnet-id,Values=$SUBNET_A_ID,$SUBNET_B_ID" "Name=availability-zone,Values=$AZ" "Name=tag:Consul-Role,Values=server" "Name=instance-state-code,Values=16" --query="Reservations[].Instances[].[PrivateIpAddress]" --output="text"
}

# Return the IP of each nomad server (in both nomad bastion subnets)
function nomad-server-ips {
    aws --region="$REGION" ec2 describe-instances --filters "Name=network-interface.subnet-id,Values=$NOMAD_SUBNET_A_ID,$NOMAD_SUBNET_B_ID" "Name=tag:Nomad-Role,Values=server" "Name=instance-state-code,Values=16" --query="Reservations[].Instances[].[PrivateIpAddress]" --output="text"
}

#
# Wait until we have as many cluster instances as we are expecting (this is managed by AWS autoscaling).
CLUSTER_INSTANCE_IPS=$(cluster-instance-ips)

while COUNT=$(echo "$CLUSTER_INSTANCE_IPS" | wc -l) && [ "$COUNT" -lt "$CONSUL_SERVER_COUNT_EXPECTED" ]
do
    echo "$COUNT instances in the cluster, waiting for $CONSUL_SERVER_COUNT_EXPECTED instances to warm up..."
    sleep 1
    CLUSTER_INSTANCE_IPS=$(cluster-instance-ids)
done

# prepare NS recursion to use consul DNS capabilties
EC2_NAMESERVER=$(grep -oP '^nameserver\s+\K([0-9\.]+)' /etc/resolv.conf)
# make sure that the script updates resolv.conf file automatically
sed -i.bak 's/PEERDNS=no/PEERDNS=yes/I' /etc/sysconfig/network-scripts/ifcfg-eth0
echo "DNS1=$$IP" >> /etc/sysconfig/network-scripts/ifcfg-eth0
echo "DNS2=$EC2_NAMESERVER" >> /etc/sysconfig/network-scripts/ifcfg-eth0
service network reload

# build the retry-join array (without our ip)
RETRY_JOINS=""
for i in $CLUSTER_INSTANCE_IPS
do 
    if ! [ "$i" == "$$IP" ]
    then
        RETRY_JOINS="$RETRY_JOINS,\"$i\""
    fi
done
RETRY_JOINS=$(echo "$RETRY_JOINS" | cut -c 2-)

cat <<- EOF | sudo tee /etc/consul.conf
{
  "datacenter"  : "$AZ",
  "node_name"   : "$INSTANCE_ID",
  "data_dir"    : "/opt/consul",
  "log_level"   : "INFO",
  "client_addr" : "0.0.0.0",
  "bind_addr"   : "$$IP",
  "recursors" : [ "$EC2_NAMESERVER" ],
  "ports" : {
    "dns" : 53
  },
  "retry_join"  : [
    $RETRY_JOINS
  ]
}
EOF

# start consul
service consul start
chkconfig consul on

# build the server array for nomad
NOMAD_SERVER_IPS=""
NOMAD_SERVICE_IPS=$(nomad-server-ips)

for i in $NOMAD_SERVICE_IPS
do 
    if ! [ "$i" == "$$IP" ]
    then
        NOMAD_SERVER_IPS="$NOMAD_SERVER_IPS,\"$i\""
    fi
done
NOMAD_SERVER_IPS=$(echo "$NOMAD_SERVER_IPS" | cut -c 2-)

cat <<- EOF | sudo tee /etc/nomad.d/nomad.json
{
  "data_dir" : "/opt/nomad",
  "name"     : "$INSTANCE_ID",
  "datacenter"  : "$AZ",
  "server": {
    "enabled"       : true,
    "bootstrap_expect" : 2,
    "retry_join" : [
      $NOMAD_SERVER_IPS
    ]
  }
}
EOF

# start nomad
service nomad start
chkconfig nomad on

# start docker
service docker start
chkconfig docker on