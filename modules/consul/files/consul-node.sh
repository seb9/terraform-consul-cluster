#!/bin/bash

# Log everything we do.
set -x
exec > /var/log/user-data.log 2>&1

# TODO: actually, userdata scripts run as root, so we can get
# rid of the sudo and tee...

# A few variables we will refer to later...
ASG_NAME="${asgname}"
REGION="${region}"
EXPECTED_SIZE="${size}"
CONSUL_SERVER_COUNT_EXPECTED="${consul_server_count_expected}"
IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

# Install consul and init script
adduser --system --no-create-home consul
curl -so /etc/init.d/consul https://gist.githubusercontent.com/sybeck2k/f948ab0f52e089735b410fcefa0bb3e2/raw/4692a0280867a7c408bc4bd1d62129cb108b9d94/gistfile1.sh && chmod +x /etc/init.d/consul
curl -so consul.zip https://releases.hashicorp.com/consul/0.8.3/consul_0.8.3_linux_amd64.zip?_ga=2.129474444.1253846471.1496136091-795717082.1477556337 && unzip consul.zip && mv consul /usr/local/sbin/ && rm consul.zip
mkdir -p {/opt/consul,/etc/consul.d}
chown consul:consul /opt/consul/
# Allow consul to bind to lower ports (DNS)
setcap 'cap_net_bind_service=+ep' /usr/local/sbin/consul

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
	log_stream_name = {instance_id}
EOF

# Create a config file for awslogs to log our docker log.
cat <<- EOF | sudo tee /etc/awslogs/config/docker.conf
	[/var/log/docker]
	file = /var/log/docker
	log_group_name = /var/log/docker
	log_stream_name = {instance_id}
	datetime_format = %Y-%m-%dT%H:%M:%S.%f
EOF

# Create a config file for awslogs to log our docker log.
cat <<- EOF | sudo tee /etc/awslogs/config/consul.conf
	[/var/log/consul]
	file = /var/log/consul
	log_group_name = /var/log/consul
	log_stream_name = {instance_id}
	datetime_format = %Y-%m-%dT%H:%M:%S.%f
EOF

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

# Return the id of each instance in the cluster.
function cluster-instance-ids {
    # Grab every line which contains 'InstanceId', cut on double quotes and grab the ID:
    #    "InstanceId": "i-example123"
    #....^..........^..^.....#4.....^...
    aws --region="$REGION" autoscaling describe-auto-scaling-groups --auto-scaling-group-name $ASG_NAME \
        | grep InstanceId \
        | cut -d '"' -f4
}

# Return the private IP of each instance in the cluster.
function cluster-ips {
    for id in $(cluster-instance-ids)
    do
        aws --region="$REGION" ec2 describe-instances \
            --query="Reservations[].Instances[].[PrivateIpAddress]" \
            --output="text" \
            --instance-ids="$id"
    done
}

function ip2dec { # Convert an IPv4 IP number to its decimal equivalent.
    declare -i a b c d;
    IFS=. read a b c d <<<"$$1";
    echo "$(((a<<24)+(b<<16)+(c<<8)+d))";
}

# Wait until we have as many cluster instances as we are expecting (this is managed by AWS autoscaling).
CLUSTER_INSTANCE_IDS=$(cluster-instance-ids)

while COUNT=$(echo "$CLUSTER_INSTANCE_IDS" | wc -l) && [ "$COUNT" -lt "$EXPECTED_SIZE" ]
do
    echo "$COUNT instances in the cluster, waiting for $EXPECTED_SIZE instances to warm up..."
    sleep 1
    CLUSTER_INSTANCE_IDS=$(cluster-instance-ids)
done


INSTANCE_IDS=""
for i in $CLUSTER_INSTANCE_IDS ; do INSTANCE_IDS="$INSTANCE_IDS $i" ; done


# Decide if we are a server or a client
# Find the count of instances with tag Consul-Role=server
SERVER_ROLE_IPS=$(aws --region="$REGION" ec2 describe-instances --filters "Name=tag:Consul-Role,Values=server" --query="Reservations[].Instances[].[PrivateIpAddress]" --instance-ids $INSTANCE_IDS --output="text")
SERVER_ROLE_INSTANCES_COUNT=0
if ! [ -z "$SERVER_ROLE_IPS" ] ; then  SERVER_ROLE_INSTANCES_COUNT=$(printf '%s\n' "$${SERVER_ROLE_IPS%$'\n'}" | wc -l); fi

IS_SERVER=0
MISSING_SERVERS_COUNT=$(expr $CONSUL_SERVER_COUNT_EXPECTED - $SERVER_ROLE_INSTANCES_COUNT)

if [ "$MISSING_SERVERS_COUNT" -gt 0 ]
then
    # we need to add servers - see if we are among them
    echo "Not enough consul servers, checking what is my role..."

    consul_undefined_role_ips=$(aws --region="$REGION" ec2 describe-instances --filters "Name=tag:Consul-Role,Values=undefined" --query="Reservations[].Instances[].[PrivateIpAddress]" --instance-ids $INSTANCE_IDS --output="text")
    
    consul_undefined_role_dec_ips=$(echo "$consul_undefined_role_ips" | while read line ; do ip2dec "$line" ; done | sort -n -r)
    my_dec_ip=$(ip2dec $$IP)

    count=0;

    for i in $consul_undefined_role_dec_ips
    do
      if [ $i -eq $my_dec_ip ]
      then
        break
      fi

      if [ $count -ge $MISSING_SERVERS_COUNT ]
      then
        break;
      fi

      let "count++"
    done

    if [ $count -lt $MISSING_SERVERS_COUNT ]
    then
      echo "I'm a consul server."
      IS_SERVER=1
      # update tags
      aws --region="$REGION" ec2 create-tags --resources $$INSTANCE_ID --tags Key=Consul-Role,Value=server
    else
      echo "I'm a consul client."
    fi
fi

echo "Instance consul role will be $IS_SERVER"

SERVER_ROLE_IPS=$(aws --region="$REGION" ec2 describe-instances --filters "Name=tag:Consul-Role,Values=server" --query="Reservations[].Instances[].[PrivateIpAddress]" --instance-ids $INSTANCE_IDS --output="text")
SERVER_ROLE_INSTANCES_COUNT=0
if ! [ -z "$SERVER_ROLE_IPS" ] ; then  SERVER_ROLE_INSTANCES_COUNT=$(printf '%s\n' "$${SERVER_ROLE_IPS%$'\n'}" | wc -l); fi

# wait that enough servers are available
while [ $SERVER_ROLE_INSTANCES_COUNT -lt $CONSUL_SERVER_COUNT_EXPECTED ]
do
    echo "$SERVER_ROLE_INSTANCES_COUNT consul servers found, waiting for $CONSUL_SERVER_COUNT_EXPECTED to be available"
    sleep 5
    SERVER_ROLE_IPS=$(aws --region="$REGION" ec2 describe-instances --filters "Name=tag:Consul-Role,Values=server" --query="Reservations[].Instances[].[PrivateIpAddress]" --instance-ids $INSTANCE_IDS --output="text")
    SERVER_ROLE_INSTANCES_COUNT=0
    if ! [ -z "$SERVER_ROLE_IPS" ] ; then  SERVER_ROLE_INSTANCES_COUNT=$(printf '%s\n' "$${SERVER_ROLE_IPS%$'\n'}" | wc -l); fi
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
for i in $SERVER_ROLE_IPS
do 
    if ! [ "$i" == "$$IP" ]
    then
        RETRY_JOINS="$RETRY_JOINS,\"$i\""
    fi
done
RETRY_JOINS=$(echo "$RETRY_JOINS" | cut -c 2-)

cat <<- EOF | sudo tee /etc/consul.conf
{
  "datacenter"  : "${region}",
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

if [ "$IS_SERVER" -eq 1 ]
then
    # Add the Consul server config
cat <<- EOF | sudo tee /etc/consul.d/server.json
{
    "server"           : true,
    "bootstrap_expect" : $CONSUL_SERVER_COUNT_EXPECTED
}
EOF
else
  # update tags
  aws --region="$REGION" ec2 create-tags --resources $$INSTANCE_ID --tags Key=Consul-Role,Value=client
fi

# start consul
service consul start
chkconfig consul on

# start docker
service docker start
chkconfig docker on