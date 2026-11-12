#!/bin/sh
echo "Starting module called 01-introduction" >> /tmp/progress.log

echo "Setting password for ansiblerunner" >> /root/post-run.log
echo "${BASTION_PASSWORD}" | passwd --stdin ansiblerunner
