#!/bin/bash -xue

# Set working directory to where the fabfile resides.
SCRIPT_DIR=$(dirname ${0})
cd ${SCRIPT_DIR}

# Remove any deployed resources on error.
trap "set +u && source heat-venv/bin/activate && fab destroy" ERR

source /tmp/manilaci-hosts
git clone https://github.com/openstack-dev/devstack.git

cat > devstack/local.conf <<-EOF
	[[local|localrc]]
	DATABASE_PASSWORD=testtest; RABBIT_PASSWORD=testtest; SERVICE_TOKEN=testtest; SERVICE_PASSWORD=testtest; ADMIN_PASSWORD=testtest;
	disable_service n-net n-xvnc n-novnc n-obj h-eng h-api h-api-cfn h-api-cw horizon cinder c-api c-sch c-vol
	enable_service q-svc q-agt q-dhcp q-l3 q-meta
	enable_plugin manila https://github.com/openstack/manila.git
	enable_plugin devstack-plugin-scality ${SCALITY_DEVSTACK_PLUGIN}
	SCREEN_LOGDIR="\${DEST}/logs"
	USE_SCALITY_FOR_GLANCE=False
EOF

devstack/stack.sh
