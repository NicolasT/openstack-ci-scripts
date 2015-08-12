#!/bin/bash -xue

TEMPEST_DIR=/opt/stack/tempest
cp -rv /opt/stack/manila/contrib/tempest/tempest/* ${TEMPEST_DIR}/tempest/
source devstack/inc/ini-config
iniset ${TEMPEST_DIR}/etc/tempest.conf service_available manila True
iniset ${TEMPEST_DIR}/etc/tempest.conf cli enabled True

cd $TEMPEST_DIR
set +u
. .tox/full/bin/activate
set -u
pip install nose

set +e
nosetests -v -w $TEMPEST_DIR/tempest/api/share/ --exe --with-xunit --xunit-file=${WORKSPACE}/tempest-api.xml
set -e

cd -
