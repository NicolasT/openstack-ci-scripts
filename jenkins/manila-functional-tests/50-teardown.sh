#!/bin/bash -xue

# Set working directory to where the fabfile resides.
SCRIPT_DIR=$(dirname ${0})
cd ${SCRIPT_DIR}

set +u && source heat-venv/bin/activate && set -u
fab destroy
