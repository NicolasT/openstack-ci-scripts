#!/bin/bash -xue

export SUP_ADMIN_LOGIN="myName"
export SUP_ADMIN_PASS="myPass"
export INTERNAL_MGMT_LOGIN="super"
export INTERNAL_MGMT_PASS="adminPass"
export HOST_IP=$(/sbin/ip addr show dev eth0 | sed -nr 's/.*inet ([0-9.]+).*/\1/p');

source jenkins/ring-install.sh

GetDistro

if [[ ($os_RELEASE =~ ^7) && ($RING_VERSION -lt 5) ]]; then
    if initialize; then
        echo "initialize should fail in that configuration"
        exit 1
    fi
else
    initialize
    add_source
    install_base_scality_node
    install_supervisor
    install_ringsh
    build_ring
    show_ring_status
    install_sproxyd
    test_sproxyd
    install_sfused
fi

cd $WORKSPACE
mkdir jenkins-logs
if [[ -f "/var/log/messages" ]]; then
    sudo cp /var/log/messages jenkins-logs/messages
elif [[ -f "/var/log/syslog" ]]; then
    sudo cp /var/log/syslog jenkins-logs/syslog
fi
sudo chown jenkins jenkins-logs/*
exit 0;
