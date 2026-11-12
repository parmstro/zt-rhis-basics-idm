#!/bin/bash

LAB_USER="ansiblerunner"
LAB_HOME="/home/${LAB_USER}"

echo "Setting password for ansiblerunner" >> /root/post-run.log
echo "redhat" | passwd --stdin ansiblerunner

dnf install -y sshpass
sleep 15

echo "Generating SSH key for ${LAB_USER}" >> /root/post-run.log
install -d -o "${LAB_USER}" -g "${LAB_USER}" -m 0700 "${LAB_HOME}/.ssh"
su - "${LAB_USER}" -c "ssh-keygen -t ed25519 -f ${LAB_HOME}/.ssh/id_ed25519 -N \"\""

for host in idm1.example.local idm2.example.local client1.example.local client2.example.local; do
  sshpass -p 'redhat' ssh-copy-id -o StrictHostKeyChecking=no -i "${LAB_HOME}/.ssh/id_ed25519.pub" "${LAB_USER}@${host}"
done
