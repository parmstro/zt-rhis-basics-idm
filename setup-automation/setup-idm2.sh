#!/bin/bash

retry() {
    for i in {1..3}; do
        echo "Attempt $i: $2"
        if $1; then
            return 0
        fi
        [ $i -lt 3 ] && sleep 5
    done
    echo "Failed after 3 attempts: $2"
    exit 1
}

echo "testing"

echo "Registering with subscription manager" > /root/post-run.log
subscription-manager clean || true
rpm -e $(rpm -qa 'katello-ca-consumer-*') 2>/dev/null || true
retry "curl -k -L https://${SATELLITE_URL}/pub/katello-server-ca.crt -o /etc/pki/ca-trust/source/anchors/${SATELLITE_URL}.ca.crt"
retry "update-ca-trust"
retry "rpm -Uhv https://${SATELLITE_URL}/pub/katello-ca-consumer-latest.noarch.rpm"
subscription-manager status
if [ $? -ne 0 ]; then
    retry "subscription-manager register --org=${SATELLITE_ORG} --activationkey=${SATELLITE_ACTIVATIONKEY}"
fi

echo "Removing GCP repos" >> /root/post-run.log
mv /etc/yum.repos.d/google-cloud.repo /root

echo "Adding rhel user" >> /root/post-run.log
usermod -aG wheel rhel

echo "Setting password for rhel" >> /root/post-run.log
echo 'redhat' | passwd --stdin rhel

echo "Adding ansiblerunner user" >> /root/post-run.log
useradd -m -G wheel ansiblerunner

echo "Setting password for ansiblerunner" >> /root/post-run.log
echo 'redhat' | passwd --stdin ansiblerunner

echo "Configuring ansiblerunner sudo privileges" >> /root/post-run.log
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

echo "Setting the hostname" >> /root/post-run.log

hostnamectl set-hostname idm2.example.local
nmcli conn mod "Wired connection 2" ipv4.addresses 192.168.0.11/23 ipv4.dns 192.168.0.10 ipv4.method manual connection.autoconnect yes
nmcli conn up "Wired connection 2" 
nmcli conn mod "Wired connection 1" ipv4.dns 192.168.0.10
nmcli conn up "Wired connection 1" 

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

echo "DONE" >> /root/post-run.log
