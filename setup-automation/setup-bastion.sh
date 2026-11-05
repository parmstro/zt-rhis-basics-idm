#!/bin/bash

subscription-manager config --rhsm.manage_repos=1
subscription-manager register --activationkey=${ACTIVATION_KEY} --org=12451665 --force

echo "remove GCP repos" >> /root/post-run.log
mv /etc/yum.repos.d/google-cloud.repo /root

echo "Adding wheel" > /root/post-run.log
usermod -aG wheel rhel
usermod -aG wheel ansiblerunner

echo "setting password" >> /root/post-run.log
echo redhat | passwd --stdin rhel
echo redhat | passwd --stdin ansiblerunner

echo "configuring ansiblerunner sudo privileges" >> /root/post-run.log
cat << EOF > /etc/sudoers.d/ansiblerunner
ansiblerunner ALL=(ALL) NOPASSWD: ALL
EOF

echo "adding ansible-core" >> /root/post-run.log
dnf install -y ansible-core bind-utils git

myip="$(hostname -I | awk '{print $1}')"
agent variable set MY_IP $myip
ssh_password=`openssl rand -base64 8`
agent variable set SSH_PASSWORD $ssh_password

agent variable set SHORTNAME $_SANDBOX_ID

echo "Configure idm network"
export IDM_PRIMARY_NAME=idm1.example.local
export IDM_REPLICA_NAME=idm2.example.local
export IDM_CLIENT1_NAME=client1.example.local
export IDM_CLIENT2_NAME=client2.example.local
export PROVISIONER_NAME=provisioner.example.local
export SUBDOMAIN=local
export REALM=${SUBDOMAIN^^}
export NETBIOS=${GUID^^}

echo "192.168.0.10 $IDM_PRIMARY_NAME" >> /etc/hosts
echo "192.168.0.11 $IDM_REPLICA_NAME" >> /etc/hosts
echo "192.168.0.20 $IDM_CLIENT1_NAME" >> /etc/hosts
echo "192.168.0.21 $IDM_CLIENT2_NAME" >> /etc/hosts
echo "192.168.0.30 $PROVISIONER_NAME" >> /etc/hosts

echo "Setting the hostname" >> /root/post-run.log

hostnamectl set-hostname provisioner.example.local

hostnamectl >> /run/post-run.log

nmcli conn mod "Wired connection 2" ipv4.addresses 192.168.0.30/24 ipv4.dns 192.168.0.10 ipv4.method manual connection.autoconnect yes
nmcli conn up "Wired connection 2" 
nmcli conn mod "Wired connection 1" ipv4.dns 192.168.0.10
nmcli conn up "Wired connection 1" 

