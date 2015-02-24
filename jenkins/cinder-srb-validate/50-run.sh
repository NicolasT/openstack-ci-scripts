#!/bin/bash -xue

export MY_LVM_CONF=/etc/lvm/lvm.conf

echo "Loading srb..."
sudo insmod ./srb/srb.ko

sudo groupadd jenkins
sudo gpasswd -a jenkins jenkins

sudo useradd -m -U stack
sudo gpasswd -a stack wheel

export ZUUL_PROJECT=openstack-dev/sandbox
export ZUUL_BRANCH=master

export PYTHONUNBUFFERED=true

export DEVSTACK_GATE_TIMEOUT=180
export DEVSTACK_GATE_TEMPEST=1
export RE_EXEC=true

export DEVSTACK_GATE_TEMPEST_REGEX=tempest.api.volume

function pre_test_hook {
    local xtrace=$(set +o | grep xtrace)
    local eerror=$(set +o | grep errexit)

    set -o xtrace
    set -o errexit

    echo "Running pre test hook"

    echo "Updating LVM configuration"
    sudo sed -i 's/# types = \[\ "fd",\ 16\ \]/types = [ "srb", 16 ]/' $MY_LVM_CONF

    echo "Setting up devstack utility scripts"
    sudo cp jenkins/cinder-srb-validate/cinder_backends/srb /opt/stack/new/devstack/lib/cinder_backends/
    sudo cp jenkins/cinder-srb-validate/cinder_plugins/srb /opt/stack/new/devstack/lib/cinder_plugins/

    echo "Reinstalling Cinder if required"
    if test -n "${JOB_CINDER_REPO:-}"; then
            sudo rm -rf /opt/stack/new/cinder
            sudo git clone ${JOB_CINDER_REPO} /opt/stack/new/cinder
            pushd /opt/stack/new/cinder
            sudo git checkout ${JOB_CINDER_BRANCH:-master}
            sudo chown -R stack `pwd`
            popd
    fi

    $eerror
    $xtrace
}
export -f pre_test_hook

DEVSTACK_LOCAL_CONFIG_FILE=$(mktemp)

cat > $DEVSTACK_LOCAL_CONFIG_FILE << EOF
CINDER_ENABLED_BACKENDS=srb:srb-1
CINDER_SRB_BASE_URLS=http://$JCLOUDS_IPS:8000/

TEMPEST_VOLUME_VENDOR='Scality'
TEMPEST_STORAGE_PROTOCOL='Scality Rest Block Device'
EOF

if test -n "${JOB_CINDER_REPO:-}"; then
        cat >> $DEVSTACK_LOCAL_CONFIG_FILE << EOF
CINDER_REPO=${JOB_CINDER_REPO}
EOF
fi

if test -n "${JOB_CINDER_BRANCH:-}"; then
        cat >> $DEVSTACK_LOCAL_CONFIG_FILE << EOF
CINDER_BRANCH=${JOB_CINDER_BRANCH}
EOF
fi

export DEVSTACK_LOCAL_CONFIG=$(cat $DEVSTACK_LOCAL_CONFIG_FILE)

rm $DEVSTACK_LOCAL_CONFIG_FILE

set +e
./devstack-gate/devstack-vm-gate-wrap.sh
RC=$?
set -e

cd $WORKSPACE
mkdir jenkins-logs
cp -R /opt/stack/logs/* jenkins-logs/
sudo chown jenkins jenkins-logs/*

exit $RC
