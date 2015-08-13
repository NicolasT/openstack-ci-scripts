#!/bin/bash -xue

if [ $USE_SCALITY_IMPL ]; then

    if [[ ! ${RING_VERSION:-} ]]; then
        RING_VERSION=4
        echo "Using ${RING_VERSION} as default value for 'RING_VERSION'"
    fi

    OS_CI_REPOSITORY=https://github.com/scality/openstack-ci-scripts.git
    NODE=$JCLOUDS_IPS
    SCRIPT_FILE=$(mktemp)

    # Accept host key
    ssh-keyscan $NODE >> ~/.ssh/known_hosts

    # Start stuff
    cat > $SCRIPT_FILE << 'EOF'
SUP_ADMIN_LOGIN="myName"
SUP_ADMIN_PASS="myPass"
INTERNAL_MGMT_LOGIN="super"
INTERNAL_MGMT_PASS="adminPass"
HOST_IP=$(/sbin/ip addr show dev eth0 | sed -nr 's/.*inet ([0-9.]+).*/\1/p');
EOF

    set +x
    cat >> $SCRIPT_FILE << EOF
set +x
SCAL_PASS=$SCAL_PASS
RING_VERSION=$RING_VERSION
set -x

sudo aptitude install -y git
git clone $OS_CI_REPOSITORY
git -C openstack-ci-scripts checkout $JOB_GIT_REVISION
. openstack-ci-scripts/jenkins/ring-install.sh
initialize
add_source
install_base_scality_node
install_supervisor
install_ringsh
build_ring
show_ring_status
install_sfused

sudo apt-get -y install nfs-common
sudo sed -i 's#"type": "fuse"#"type": "nfs"#' /etc/sfused.conf
sudo sh -c 'echo "/ 127.0.0.1(rw,no_root_squash)" > /etc/exports.conf'
sudo service scality-sfused restart

sudo apt-get install -y python-pbr python-setuptools python-pip git
sudo pip install git+https://github.com/scality/scality-manila-utils.git

EOF
    set -x

    chmod a+x $SCRIPT_FILE

    scp $SCRIPT_FILE $NODE:
    ssh $NODE /bin/bash -xue $(basename $SCRIPT_FILE)
fi
