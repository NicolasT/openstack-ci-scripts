#!/bin/bash -xue

# Set working directory to where the fabfile resides.
SCRIPT_DIR=$(dirname ${0})
cd ${SCRIPT_DIR}

sudo apt-get update
sudo apt-get -y install git-core python-dev python-virtualenv

# Install heat in a virtualenv to not interfere with devstack dependencies
virtualenv heat-venv
set +u && source heat-venv/bin/activate && set -u
pip install python-heatclient fabric

ssh-keygen -t rsa -P '' -C manila-management -f ${MANAGEMENT_KEY_PATH}

# Remove any deployed resources on error.
trap "fab destroy" ERR

# Connection attempts are bumped here to give sshd time to
# start on the deployed infrastructure.
fab deploy:"`cat ${MANAGEMENT_KEY_PATH}.pub`" --connection-attempts 10 \
	-i ${MANAGEMENT_KEY_PATH} -u ${MANAGEMENT_USER}
