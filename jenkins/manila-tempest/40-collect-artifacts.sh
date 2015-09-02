#!/bin/bash -xue

echo "Entering WORKSPACE."
cd $WORKSPACE
mkdir jenkins-logs
echo "Creating jenkins-log directory."
cp -R /opt/stack/logs/* jenkins-logs/
if [[ -f "/var/log/messages" ]]; then
    sudo cp /var/log/messages jenkins-logs/messages
fi
if [[ -f "/var/log/syslog" ]]; then
    sudo cp /var/log/syslog jenkins-logs/syslog
fi
ssh $JCLOUDS_IPS "sudo chmod o+r /var/log/syslog"
scp $JCLOUDS_IPS:/var/log/syslog jenkins-logs/nfs-server-syslog
sudo chown jenkins jenkins-logs/*
exit 0;
