#!/bin/bash -xue

SCRIPT_DIR=$(cd $(dirname ${0}) && pwd)
trap "cd ${SCRIPT_DIR} && set +u && source heat-venv/bin/activate && fab destroy" ERR

ARTIFACT_DIR=${WORKSPACE}/artifacts
JENKINS_ARTIFACT_DIR=${ARTIFACT_DIR}/jenkins

mkdir -p ${ARTIFACT_DIR}

# Grab logs from jenkins host
mkdir ${JENKINS_ARTIFACT_DIR}
# || true has been added to workaround this failure:
# "cp: cannot stat ‘xxx’: No such file or directory"
cp -rL /opt/stack/logs/* ${JENKINS_ARTIFACT_DIR} || true

if [[ -f "/var/log/messages" ]]; then
    sudo cp /var/log/messages ${JENKINS_ARTIFACT_DIR}
fi

if [[ -f "/var/log/syslog" ]]; then
    sudo cp /var/log/syslog ${JENKINS_ARTIFACT_DIR}
fi

# TODO Grab logs from ring and connector nodes.
#RING_ARTIFACT_DIR=
#NFS_ARTIFACT_DIR=
#CIFS_ARTIFACT_DIR=

# || true has been added to workaround this failure:
# "chown fails with chown: cannot dereference ‘jenkins-logs/xx’:
# No such file or directory"
sudo chown -R jenkins: ${ARTIFACT_DIR} || true
