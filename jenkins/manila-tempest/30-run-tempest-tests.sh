#!/bin/bash -xue

TEMPEST_DIR=/opt/stack/tempest
cp -rv /opt/stack/manila/contrib/tempest/tempest/* ${TEMPEST_DIR}/tempest/
source devstack/inc/ini-config
iniset ${TEMPEST_DIR}/etc/tempest.conf service_available manila True
iniset ${TEMPEST_DIR}/etc/tempest.conf cli enabled True
iniset ${TEMPEST_DIR}/etc/tempest.conf share multitenancy_enabled False
iniset ${TEMPEST_DIR}/etc/tempest.conf share enable_protocols nfs
iniset ${TEMPEST_DIR}/etc/tempest.conf share run_extend_tests False
iniset ${TEMPEST_DIR}/etc/tempest.conf share run_shrink_tests False
iniset ${TEMPEST_DIR}/etc/tempest.conf share run_snapshot_tests False
iniset ${TEMPEST_DIR}/etc/tempest.conf share storage_protocol NFS

cd $TEMPEST_DIR
set +u
. .tox/full/bin/activate
set -u
pip install nose

set +e
nosetests -v -w $TEMPEST_DIR/tempest/api/share/ --exe --with-xunit --xunit-file=${WORKSPACE}/tempest-api.xml
set -e

cd -
