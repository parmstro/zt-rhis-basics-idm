#!/bin/bash

echo "testing"

echo "Registering with subscription manager" > /root/post-run.log
subscription-manager config --rhsm.manage_repos=1
subscription-manager unregister
sleep 10
echo "Registering with activation key: ${SATELLITE_ACTIVATIONKEY}" >> /root/post-run.log
subscription-manager register --activationkey=${SATELLITE_ACTIVATIONKEY} --org=12451665 --force

echo "Removing GCP repos" >> /root/post-run.log
mv /etc/yum.repos.d/google-cloud.repo /root

# just create our ansiblerunner user and add it to the wheel group
echo "Setting password for rhel" >> /root/post-run.log
echo "${BASTION_PASSWORD}" | passwd --stdin rhel

echo "Adding ansiblerunner user" >> /root/post-run.log
useradd -mG wheel ansiblerunner

echo "Setting password for ansiblerunner" >> /root/post-run.log
echo "${BASTION_PASSWORD}" | passwd --stdin ansiblerunner

cp /etc/sudoers.d/rhel /etc/sudoers.d/ansiblerunner
sed -i 's/rhel/ansiblerunner/g' /etc/sudoers.d/ansiblerunner

tee -a /root/.ssh/config << EOF
Host *
    StrictHostKeyChecking no
EOF

chmod 400 /root/.ssh/config

dnf -y update

echo "Configure idm network" >> /root/post-run.log
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

hostnamectl set-hostname idm1.example.local

hostnamectl >> /root/post-run.log

nmcli conn mod "Wired connection 2" ipv4.addresses 192.168.0.10/23 ipv4.method manual connection.autoconnect yes
nmcli conn up "Wired connection 2" 

# rhel user is already part of wheel
echo "Enable bash completion in the root's shell" >> /root/post-run.log
echo "source /etc/profile.d/bash_completion.sh" >> /root/.bashrc

echo "Install the ipa-server packages" >> /root/post-run.log
dnf -y install ipa-server ipa-server-dns ipa-healthcheck firewalld net-tools

echo "Configure the firewall for IdM Server" >> /root/post-run.log
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

# # add a time server as they aren't provided by default
# # they don't let us out...
# echo "server    time.chu.nrc.ca         iburst" >> /etc/chrony.conf
# echo "server    0.pool.utoronto.ca      iburst" >> /etc/chrony.conf
# echo "server    1.pool.utoronto.ca      iburst" >> /etc/chrony.conf

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

echo "Set the timezone" >> /root/post-run.log
timedatectl set-timezone America/Toronto

tee -a /root/ipa-web.sh << EOF
#!/bin/bash
tee /etc/httpd/conf.d/ipa-rewrite.conf << IPA
# VERSION 7 - DO NOT REMOVE THIS LINE

RequestHeader set Host idm1.example.local
RequestHeader set Referer https://idm1.example.local/ipa/ui/
RewriteEngine on

# Rewrite for plugin index, make it like it's a static file
RewriteRule ^/ipa/ui/js/freeipa/plugins.js$    /ipa/wsgi/plugins.py [PT]

RewriteCond %{HTTP_HOST}    ^ipa-ca.example.local$ [NC]
RewriteCond %{REQUEST_URI}  !^/ipa/crl
RewriteCond %{REQUEST_URI}  !^/(ca|kra|pki|acme)
IPA
systemctl reload httpd
EOF
chmod +x /root/ipa-web.sh

echo "DONE" >> /root/post-run.log
