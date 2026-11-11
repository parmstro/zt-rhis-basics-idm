#!/bin/bash

echo "Generating SSH key for ansiblerunner" >> /root/post-run.log
install -d -o ansiblerunner -g ansiblerunner -m 0700 /home/ansiblerunner/.ssh
su - ansiblerunner -c 'ssh-keygen -t ed25519 -f /home/ansiblerunner/.ssh/id_ed25519 -N ""'

dnf install -y sshpass
for host in idm1.example.local idm2.example.local client1.example.local client2.example.local; do
  sshpass -p 'redhat' ssh-copy-id -o StrictHostKeyChecking=no -i /home/ansiblerunner/.ssh/id_ed25519.pub ansiblerunner@"$host"
done
