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
git clone -b master https://github.com/openstack-dev/devstack.git
cp devstack/samples/local.conf devstack/local.conf
cat >> devstack/local.conf <<EOF
disable_service horizon n-net
enable_service neutron q-svc q-agt q-dhcp q-l3 q-meta
enable_plugin manila $MANILA_REPO $MANILA_BRANCH
SCREEN_LOGDIR="\${DEST}/logs"
EOF

if [ $USE_SCALITY_IMPL ]; then

    export MANILA_ENABLED_BACKENDS="ring"
    export MANILA_DEFAULT_SHARE_TYPE="scality"
    export MANILA_DEFAULT_SHARE_TYPE_EXTRA_SPECS="share_backend_name=scality_ring"

    cat >> devstack/local.conf <<EOF
[[post-config|/etc/manila/manila.conf]]
[ring]
driver_handles_share_servers=False
share_backend_name=scality_ring
share_driver=manila.share.drivers.scality.driver.ScalityShareDriver
export_management_host=$JCLOUDS_IPS
management_user=jenkins
export_ip=$JCLOUDS_IPS
EOF

fi


./devstack/stack.sh
