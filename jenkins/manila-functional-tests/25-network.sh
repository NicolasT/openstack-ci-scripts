#!/bin/bash -xue

# Set working directory to where the fabfile resides.
SCRIPT_DIR=$(dirname ${0})
cd ${SCRIPT_DIR}

set +u && source heat-venv/bin/activate && set -u
trap "fab destroy" ERR

source /opt/stack/devstack-plugin-scality/environment/netdef
source /tmp/manilaci-hosts

HOST_IP=$(/sbin/ip addr show dev eth0 | sed -nr 's/.*inet ([0-9.]+).*/\1/p')

# Allow fab tasks to execute locally.
cat ${MANAGEMENT_KEY_PATH}.pub >> ~/.ssh/authorized_keys

fab configure_network_path:local_ip=${HOST_IP},nfs_ip=${NFS_CONNECTOR_HOST},cifs_ip=${CIFS_CONNECTOR_HOST} \
	-i ${MANAGEMENT_KEY_PATH} -u ${MANAGEMENT_USER}
