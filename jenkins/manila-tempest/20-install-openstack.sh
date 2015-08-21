#!/bin/bash -xue

if [[ ! ${MANILA_REPO:-} ]]; then
    MANILA_REPO="https://github.com/openstack/manila"
    echo "Using ${MANILA_REPO} as default value for 'MANILA_REPO'"
fi

if [[ ! ${MANILA_BRANCH:-} ]]; then
    MANILA_BRANCH="master"
    echo "Using ${MANILA_BRANCH} as default value for 'MANILA_BRANCH'"
fi

ssh-keygen -y -f $HOME/.ssh/id_rsa > $HOME/.ssh/id_rsa.pub

wget https://bootstrap.pypa.io/ez_setup.py -O - | sudo python;
sudo easy_install pip
sudo easy_install -U six

# Clone devstack
git clone -b master https://github.com/openstack-dev/devstack.git

# Copy bridge configuration scripts for the provider network where manila shares are exposed
cp jenkins/${JOB_NAME%%/*}/extras.d/* devstack/extras.d

# Source network definitions
source devstack/extras.d/netdef

# Configure manila
cp devstack/samples/local.conf devstack/local.conf
cat >> devstack/local.conf <<EOF
disable_service horizon n-net n-novnc cinder c-api c-sch c-vol
enable_service neutron q-svc q-agt q-dhcp q-l3 q-meta
enable_plugin manila $MANILA_REPO $MANILA_BRANCH
SCREEN_LOGDIR="\${DEST}/logs"
EOF

if [[ $USE_SCALITY_IMPL == true ]]; then
    # Manila general section
    export MANILA_ENABLED_BACKENDS="ring"
    export MANILA_DEFAULT_SHARE_TYPE="scality"
    export MANILA_DEFAULT_SHARE_TYPE_EXTRA_SPECS="share_backend_name=scality_ring"

    # Manila ring section
    export MANILA_OPTGROUP_ring_driver_handles_share_servers=False
    export MANILA_OPTGROUP_ring_share_backend_name=scality_ring
    export MANILA_OPTGROUP_ring_share_driver=manila.share.drivers.scality.driver.ScalityShareDriver
    export MANILA_OPTGROUP_ring_export_management_host=$JCLOUDS_IPS
    export MANILA_OPTGROUP_ring_management_user=jenkins
    export MANILA_OPTGROUP_ring_export_ip=$RING_EXPORTS_GW

fi

./devstack/stack.sh
