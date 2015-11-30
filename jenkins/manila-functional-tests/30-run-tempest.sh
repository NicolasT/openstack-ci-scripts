#!/bin/bash -xue

SCRIPT_DIR=$(cd $(dirname ${0}) && pwd)

# Manila tempest tests are compatible with a specific version of tempest,
# which is defined in common.sh. This basically defines a few bash functions in
# addition to MANILA_TEMPEST_COMMIT.
set +eu
source /opt/stack/manila/contrib/ci/common.sh
set -eu

# Remove any deployed resources on error.
trap "cd ${SCRIPT_DIR} && set +u && source heat-venv/bin/activate && fab destroy" ERR

cd /opt/stack/tempest
git reset --hard ${MANILA_TEMPEST_COMMIT}  # Commit used in manila gate jobs
tox -e all-plugin manila_tempest_tests.tests.api

# Create a test result report
set +e
sudo pip install python-subunit junitxml
if [ $? -eq 0 ]; then
	testr last --subunit | subunit2junitxml -o ${WORKSPACE}/manila-functional-tests.xml
fi
set -e
