#!/bin/bash -xue

sudo groupadd jenkins
sudo gpasswd -a jenkins jenkins

sudo useradd -m -U stack
sudo gpasswd -a stack wheel

export ZUUL_PROJECT=${GERRIT_PROJECT:-}
export ZUUL_BRANCH=${GERRIT_BRANCH:-master}
export ZUUL_REF=${GERRIT_REFSPEC:-}
export ZUUL_PATCHET=${GERRIT_PATCHSET_NUMBER:-}
export ZUUL_CHANGE=${GERRIT_CHANGE_NUMBER:-}

if [ ! -z "${GERRIT_HOST:-}" ]; then
    export ZUUL_URL=https://$GERRIT_HOST
fi

export PYTHONUNBUFFERED=true

export DEVSTACK_GATE_TIMEOUT=180
export DEVSTACK_GATE_TEMPEST=1
export RE_EXEC=true

# The SOFS driver in Juno and Icehouse doesn't support volume backup
# nor is compatible with "cinder multi backend".
# Since we don't run volume backup, we don't need Swift
extra_disabled_services=""
if [[ ${ZUUL_BRANCH} =~ "juno" || ${ZUUL_BRANCH} =~ "icehouse" ]]; then
    export DEVSTACK_GATE_TEMPEST_REGEX='tempest.api.volume.(?!.*(test_volume_backup|volume_type_and_extra_specs))'
    extra_disabled_services="c-bak s-proxy s-object s-container s-account"
else
    export DEVSTACK_GATE_TEMPEST_REGEX='tempest.api.volume'
fi

function pre_test_hook() {
    local xtrace=$(set +o | grep xtrace)
    local eerror=$(set +o | grep errexit)

    set -o xtrace
    set -o errexit

    echo "Running pre test hook"

    echo "Setting up devstack utility scripts"
    sudo cp jenkins/cinder-sofs-validate/cinder_backends/sofs /opt/stack/new/devstack/lib/cinder_backends/
    sudo cp jenkins/cinder-sofs-validate/extras.d/60-sofs.sh /opt/stack/new/devstack/extras.d/

    $eerror
    $xtrace
}
export -f pre_test_hook

DEVSTACK_LOCAL_CONFIG_FILE=$(mktemp)

cat > $DEVSTACK_LOCAL_CONFIG_FILE << EOF
CINDER_ENABLED_BACKENDS=sofs:sofs-1

TEMPEST_VOLUME_VENDOR=Scality
TEMPEST_STORAGE_PROTOCOL=scality

LIBVIRT_TYPE=qemu
disable_service $extra_disabled_services heat h-eng h-api h-api-cfn h-api-cw horizon trove tr-api tr-cond tr-tmgr sahara ceilometer-acompute ceilometer-acentral ceilometer-anotification ceilometer-collector ceilometer-alarm-evaluator ceilometer-alarm-notifier ceilometer-api
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

# Reclone=yes doesn't play nicely with devstack-gate because it will override
# the work done in devstack-gate/functions.sh::setup_project()
# Set Reclone, iff this build is triggered manually and the canonical
# repo/branch is overridden
if test -n "${JOB_CINDER_REPO:-}" -o -n "${JOB_CINDER_BRANCH:-}"; then
    cat >> $DEVSTACK_LOCAL_CONFIG_FILE << EOF
RECLONE=yes
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
