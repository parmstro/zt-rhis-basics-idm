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

echo "Remove GCP repos" >> /root/post-run.log
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
