#!/bin/bash

# Define the log file paths
LOG_FILE="/root/post-run.log"

# Redirect stdout and stderr into a tee process
exec > >(tee -a "$LOG_FILE") 2>&1

subscription-manager config --rhsm.manage_repos=1
subscription-manager register --activationkey=${ACTIVATION_KEY} --org=12451665 --force

echo "remove GCP repos"
mv /etc/yum.repos.d/google-cloud.repo /root

echo "Adding rhel user"
usermod -aG wheel rhel

echo "setting password for rhel"
echo 'redhat' | passwd --stdin rhel

echo "Adding ansiblerunner user"
useradd -mG wheel ansiblerunner

echo "setting password for ansiblerunner"
echo 'redhat' | passwd --stdin ansiblerunner

echo "configuring ansiblerunner sudo privileges"
cat << EOF > /etc/sudoers.d/ansiblerunner
ansiblerunner ALL=(ALL) NOPASSWD: ALL
EOF

tee -a /root/.ssh/config << EOF
Host *
    StrictHostKeyChecking no
EOF

chmod 400 /root/.ssh/config

dnf -y update

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

echo "Setting the hostname"

hostnamectl set-hostname idm2.example.local
hostnamectl

nmcli conn mod "Wired connection 2" ipv4.addresses 192.168.0.11/24 ipv4.dns 192.168.0.10 ipv4.method manual connection.autoconnect yes
nmcli conn up "Wired connection 2" 
nmcli conn mod "Wired connection 1" ipv4.dns 192.168.0.10
nmcli conn up "Wired connection 1" 

# rhel user is already part of wheel
echo "enable bash completion in the root's shell"
echo "source /etc/profile.d/bash_completion.sh" >> /root/.bashrc

echo "Install the ipa-server packages"
dnf -y install ipa-server ipa-server-dns ipa-healthcheck firewalld net-tools

echo "Configure the firewall for IdM Server"
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=http  # redundant really
firewall-cmd --permanent --add-service=https # redundant really
firewall-cmd --permanent --add-service=freeipa-4
firewall-cmd --permanent --add-service=freeipa-ldap
firewall-cmd --permanent --add-service=freeipa-ldaps
firewall-cmd --permanent --add-service=freeipa-replication
firewall-cmd --permanent --add-service=freeipa-trust
firewall-cmd --reload

tee -a /root/trustednetwork.sh << EOF
#!/bin/bash
mv /etc/named/ipa-ext.conf /etc/named/ipa-ext.\$(date +"%s").bak
tee -a /etc/named/ipa-ext.conf << TRUSTED
acl "trusted_network" { 
    localnets; 
    localhost; 
    192.168.0.0/24; 
};
TRUSTED

mv /etc/named/ipa-options-ext.conf /etc/named/ipa-options-ext.\$(date +"%s").bak
tee -a /etc/named/ipa-options-ext.conf << OPTIONS
allow-recursion { trusted_network; };
allow-query-cache  { trusted_network; };
dnssec-validation yes;
OPTIONS

EOF

chmod +x /root/trustednetwork.sh

echo "Set the timezone"
timedatectl set-timezone America/Toronto

echo "DONE"
