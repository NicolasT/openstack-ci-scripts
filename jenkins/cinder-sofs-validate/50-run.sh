#!/bin/bash -xue

sudo groupadd jenkins
sudo gpasswd -a jenkins jenkins
sudo chown -R jenkins:jenkins /opt/git/

echo "#includedir /etc/sudoers.d" | sudo tee -a /etc/sudoers

export ZUUL_PROJECT=${GERRIT_PROJECT:-}
export ZUUL_BRANCH=${GERRIT_BRANCH:-master}
export ZUUL_REF=${GERRIT_REFSPEC:-}
export ZUUL_PATCHET=${GERRIT_PATCHSET_NUMBER:-}
export ZUUL_CHANGE=${GERRIT_CHANGE_NUMBER:-}

if [ -n  "${GERRIT_HOST:-}" ]; then
    export ZUUL_URL=https://$GERRIT_HOST
fi

export PYTHONUNBUFFERED=true

export DEVSTACK_GATE_TIMEOUT=180
export DEVSTACK_GATE_TEMPEST=1
export TEMPEST_CONCURRENCY=2
export RE_EXEC=true


export DEVSTACK_GATE_TEMPEST_REGEX='volume'

DEVSTACK_LOCAL_CONFIG_FILE=$(mktemp)

cat > $DEVSTACK_LOCAL_CONFIG_FILE << EOF
CINDER_ENABLED_BACKENDS=sofs:sofs-1
BUILD_TIMEOUT=300

ATTACH_ENCRYPTED_VOLUME_AVAILABLE=False

# For some reason devstack-gate overwrite this variable
FIXED_RANGE=10.0.0.0/24

enable_service q-svc q-agt q-dhcp q-l3 q-meta
disable_service n-net heat h-eng h-api h-api-cfn h-api-cw horizon trove tr-api tr-cond tr-tmgr sahara ceilometer-acompute ceilometer-acentral ceilometer-anotification ceilometer-collector ceilometer-alarm-evaluator ceilometer-alarm-notifier ceilometer-api

# 167.88.149.196 is a physical server in the Scality OpenStack Lab. It hosts a copy
# of github.com/scality/devstack-plugin-scality to avoid Github's rate limiting.
enable_plugin scality git://167.88.149.196/devstack-plugin-scality
SCALITY_SPROXYD_ENDPOINTS=http://127.0.0.1:81/proxy/bpchord
USE_SCALITY_FOR_SWIFT=False
USE_SCALITY_FOR_GLANCE=False
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

# The following line is required otherwise devstack fails with "The /opt/stack/new/scality
# project was not found; if this is a gate job, add the project to the $PROJECTS
# variable in the job definition." See
# https://github.com/openstack-dev/devstack/blob/a5ea08b7526bee0d9cab51000a477654726de8fe/functions-common#L536
export PROJECTS="scality"
git clone git://167.88.149.196/devstack-plugin-scality /opt/git/scality

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

# Create a test result report
set +e
sudo pip install python-subunit junitxml
if [ $? -eq 0 ]; then
	gunzip -c /opt/stack/logs/testrepository.subunit.gz | subunit2junitxml -o ${WORKSPACE}/cinder-sofs-validate.xml
fi
touch ${WORKSPACE}/cinder-sofs-validate.xml
set -e

exit $RC
