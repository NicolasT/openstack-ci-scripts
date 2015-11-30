#!/bin/bash -xue

# Set working directory to where the fabfile resides.
SCRIPT_DIR=$(dirname ${0})
cd ${SCRIPT_DIR}

# Remove any deployed resources on error.
trap "set +u && source heat-venv/bin/activate && fab destroy" ERR

source /tmp/manilaci-hosts
git clone https://github.com/openstack-dev/devstack.git
cp devstack/samples/local.conf devstack

cat >> devstack/local.conf << EOF
disable_service horizon n-net n-novnc cinder c-api c-sch c-vol
enable_plugin manila https://github.com/openstack/manila.git
enable_plugin scality-manila-devstack-plugin ${SCALITY_DEVSTACK_PLUGIN}
SCREEN_LOGDIR="\${DEST}/logs"
EOF

devstack/stack.sh
