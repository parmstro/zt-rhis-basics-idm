#!/bin/bash

echo "testing"

echo "Registering with subscription manager" > /root/post-run.log
subscription-manager config --rhsm.manage_repos=1
subscription-manager register --activationkey=${ACTIVATION_KEY} --org=12451665 --force

echo "Remove GCP repos" >> /root/post-run.log
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
hostnamectl set-hostname client2.example.local

nmcli conn mod "Wired connection 2" ipv4.addresses 192.168.0.21/23 ipv4.dns 192.168.0.10 ipv4.method manual connection.autoconnect yes
nmcli conn up "Wired connection 2" 
nmcli conn mod "Wired connection 1" ipv4.dns 192.168.0.10
nmcli conn up "Wired connection 1" 

# Enable cockpit functionality in showroom.
echo "[WebService]" > /etc/cockpit/cockpit.conf
echo "Origins = https://cockpit-${GUID}.${DOMAIN}" >> /etc/cockpit/cockpit.conf
echo "AllowUnencrypted = true" >> /etc/cockpit/cockpit.conf
systemctl enable --now cockpit.socket

echo "Enable bash completion in the root's shell" >> /root/post-run.log
echo "source /etc/profile.d/bash_completion.sh" >> /root/.bashrc

echo "Install the ipa-client packages and lab packages" >> /root/post-run.log
dnf -y install firewalld bind-utils net-tools sssd-dbus vim nano ipa-client httpd mod_lookup_identity mod_authnz_pam mod_wsgi haveged nmap-ncat pamtester bash-completion

echo "Configure the firewall for httpd" >> /root/post-run.log
systemctl enable --now firewalld
firewall-cmd --permanent --add-service http
firewall-cmd --reload

rm -f /etc/httpd/conf.d/welcome.conf

cat >/usr/share/httpd/app.py <<EOF
def application(environ, start_response):
    start_response('200 OK', [('Content-Type', 'text/plain')])
    remote_user = environ.get('REMOTE_USER')

    if remote_user is not None:
        yield "LOGGED IN AS: {}\n".format(remote_user).encode('utf8')
    else:
        yield b"NOT LOGGED IN\n"

    yield b"\nREMOTE_* REQUEST VARIABLES:\n\n"

    for k, v in environ.items():
        if k.startswith('REMOTE_'):
            yield "  {}: {}\n".format(k, v).encode('utf8')
EOF

cat >/etc/httpd/conf.d/app.conf <<EOF
<VirtualHost *:80>
    ServerName client2.example.local
    WSGIScriptAlias / /usr/share/httpd/app.py

    <Directory /usr/share/httpd>
        <Files "app.py">
            Require all granted
        </Files>
    </Directory>
</VirtualHost>
EOF

echo "Set the timezone" >> /root/post-run.log
timedatectl set-timezone America/Toronto

echo "DONE" >> /root/post-run.log
