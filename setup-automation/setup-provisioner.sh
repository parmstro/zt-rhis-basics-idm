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

# Define the log file paths

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

echo "Adding ansible-core" >> /root/post-run.log
dnf install -y ansible-core \
               bind-utils \
               git \
               wget \
               unzip \
               vim \
               tree \
               container-tools

myip="$(hostname -I | awk '{print $1}')"
agent variable set MY_IP $myip
agent variable set SSH_PASSWORD "redhat"

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

nmcli conn mod "Wired connection 2" ipv4.addresses 192.168.0.30/23 ipv4.dns 192.168.0.10 ipv4.method manual connection.autoconnect yes
nmcli conn up "Wired connection 2" 
nmcli conn mod "Wired connection 1" ipv4.dns 192.168.0.10
nmcli conn up "Wired connection 1" 

# VSCode Server deployment
CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-4.138.0}"
CODE_SERVER_PASSWORD="redhat"
LAB_USER="ansiblerunner"
LAB_HOME="/home/${LAB_USER}"
WORKSPACE="${LAB_HOME}/rhis"

mkdir -p "${WORKSPACE}"

if ! command -v code-server >/dev/null 2>&1; then
  case "$(uname -m)" in
    x86_64)
      CODE_SERVER_ARCH="amd64"
      ;;
    *)
      echo "Unsupported architecture for code-server: $(uname -m)" >&2
      exit 1
      ;;
  esac

  CODE_SERVER_RPM="/var/tmp/code-server-${CODE_SERVER_VERSION}-${CODE_SERVER_ARCH}.rpm"
  CODE_SERVER_URL="https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-${CODE_SERVER_ARCH}.rpm"

  echo "Installing code-server ${CODE_SERVER_VERSION}"
  curl --fail --location --retry 3 --output "${CODE_SERVER_RPM}" "${CODE_SERVER_URL}"
  rpm -Uvh "${CODE_SERVER_RPM}"
  rm -f "${CODE_SERVER_RPM}"
fi

echo "Configuring code-server for ${LAB_USER}" >> /root/post-run.log
install -d -o "${LAB_USER}" -g "${LAB_USER}" -m 0700 "${LAB_HOME}/.config/code-server"
printf '%s\n' \
  'bind-addr: 0.0.0.0:8080' \
  'auth: password' \
  "password: ${CODE_SERVER_PASSWORD}" \
  'cert: false' \
  > "${LAB_HOME}/.config/code-server/config.yaml"
chown "${LAB_USER}:${LAB_USER}" "${LAB_HOME}/.config/code-server/config.yaml"
chmod 0600 "${LAB_HOME}/.config/code-server/config.yaml"

# Keep Ansible extension settings outside the learner workspace. In particular,
# disabling validation prevents ansible-lint from creating .ansible directories
# next to the lesson files.
VSCODE_USER_DIR="${LAB_HOME}/.local/share/code-server/User"
install -d -o "${LAB_USER}" -g "${LAB_USER}" -m 0700 "${VSCODE_USER_DIR}"
printf '%s\n' \
  '{' \
  '  "ansible.python.interpreterPath": "/usr/bin/python3",' \
  '  "ansible.validation.enabled": false,' \
  '  "ansible.validation.lint.enabled": false,' \
  '  "security.workspace.trust.enabled": false' \
  '}' \
  > "${VSCODE_USER_DIR}/settings.json"
chown "${LAB_USER}:${LAB_USER}" "${VSCODE_USER_DIR}/settings.json"
chmod 0600 "${VSCODE_USER_DIR}/settings.json"

# Keep the user service alive after the provisioning connection closes.
loginctl enable-linger "${LAB_USER}"
sudo chown -R "${LAB_USER}:${LAB_USER}" "/home/${LAB_USER}"
sudo systemctl --user -M "${LAB_USER}@" enable code-server.service
sudo systemctl --user -M "${LAB_USER}@" restart code-server.service
sudo systemctl --user -M "${LAB_USER}@" status code-server.service

echo "code-server is listening on host1 TCP/8080 with ${WORKSPACE} ready to open." >> /root/post-run.log
echo "A CNV route or proxy is still required before the Showroom browser tab can reach it." >> /root/post-run.log
