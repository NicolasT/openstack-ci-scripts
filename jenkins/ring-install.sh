#!/bin/bash -xue

# Public functions : 
#   * initialize
#   * add_source
#   * install_base_scality_node
#   * install_supervisor
#   * install_ringsh
#   * build_ring
#   * show_ring_status
#   * install_sproxyd
#   * install_sfused
# 
# 'initialize' should be called before any other public method invocation.
#

test -n "${SUP_ADMIN_LOGIN:-}" || (echo "SUP_ADMIN_LOGIN should be defined." && return 1);
test -n "${SUP_ADMIN_PASS:-}" || (echo "SUP_ADMIN_PASS should be defined." && return 1);
test -n "${INTERNAL_MGMT_LOGIN:-}" || (echo "INTERNAL_MGMT_LOGIN should be defined." && return 1);
test -n "${INTERNAL_MGMT_PASS:-}" || (echo "INTERNAL_MGMT_PASS should be defined." && return 1);
test -n "${HOST_IP:-}" || (echo "HOST_IP should be defined." && return 1);

RING_VERSION=${RING_VERSION:-5}
if [[ $RING_VERSION == 4 ]]; then
    RING_CODENAME="khamul"
elif [[ $RING_VERSION == 5 ]]; then
    RING_CODENAME="lorien"
else
    echo "This installer can only install Scality Ring 4 or Ring 5, '$RING_VERSION' is an invalid value"
    return 1
fi

if [[ ! ${AllowEncodedSlashes:-} ]]; then
    AllowEncodedSlashes="Off"
    echo "Using 'Off' as default value for 'AllowEncodedSlashes'"
fi

if [[ ! ${KeepAlive:-} ]]; then
    KeepAlive="On"
    echo "Using 'On' as default value for 'KeepAlive'"
elif [[ $KeepAlive != 'On' &&  $KeepAlive != 'Off' ]]; then
    echo "The only valid values for KeepAlive are 'On' and 'Off', $KeepAlive is an invalid value"
    return 1
fi

export DEBIAN_FRONTEND="noninteractive"

function source_distro_utils {
    local current_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
    source $current_dir/distro-utils.sh
}

source_distro_utils

function initialize {
    distro_dispatch initialize_centos initialize_ubuntu
}

function initialize_centos {
    PATH=$PATH:/sbin:/usr/sbin
    # https://docs.scality.com/display/R43/Requirements+and+Recommendations+for+Installation#RequirementsandRecommendationsforInstallation-IncompatibleSoftware
    sudo setenforce 0
}

function initialize_ubuntu {
    echo "Nothing specific here."
}

function add_source {
    distro_dispatch add_source_centos add_source_ubuntu
}

function add_source_centos {
    set +x
    sudo sh -c "cat <<-EOF >/etc/yum.repos.d/scality${RING_VERSION}.repo
[scality-base]
name=Centos6 - Scality Base
baseurl=http://${SCAL_PASS}@packages.scality.com/stable_${RING_CODENAME}/centos/6/x86_64/
gpgcheck=0
EOF"
    set -x
    sudo rpm -Uvh http://mirror.cogentco.com/pub/linux/epel/6/i386/epel-release-6-8.noarch.rpm
}

function add_source_ubuntu {
    # subshell trick, do not output the password to stdout
    (set +x; echo "deb [arch=amd64] http://${SCAL_PASS}@packages.scality.com/stable_${RING_CODENAME}/ubuntu/ $(lsb_release -c -s) main" | sudo tee /etc/apt/sources.list.d/scality${RING_VERSION}.list &>/dev/null)

    if [[ $RING_VERSION == 4 ]]; then
        local gpg_key=5B1943DD
    else
        local gpg_key=4A23AD0E
    fi

    # We use 2 alternative methods to add the key because the script can also
    # be used outside of Jenkins context (in a standalone way)
    if ! gpg --keyserver keys.gnupg.net --recv-keys $gpg_key; then
        local current_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
        sudo apt-key add $current_dir/scality${RING_VERSION}.gpg
    else
        gpg -a --export $gpg_key | sudo apt-key add -
    fi

    # snmp-mibs-downloader is a dependency. It is only available in Ubuntu multiverse :
    sudo sed -ri "s/^#\s+(.*multiverse.*)/\1/" /etc/apt/sources.list
    sudo apt-get update
}

function _prepare_datadir_on_tmpfs {
    sudo mkdir -p /scalitytest/disk1
    # be sure we don't mount multiple times
    if [[ -z "$(mount -l | grep /scalitytest/disk1)" ]]; then
        sudo mount -t tmpfs -o size=60g tmpfs /scalitytest/disk1
    fi
}

function _prepare_datadir_on_fs {
    sudo mkdir -p /scalitytest/disk1
}

function _install_dependencies_ubuntu {
    install_packages debconf-utils snmp
}

function _install_dependencies_centos {
    install_packages net-snmp net-snmp-utils
}

function _tune_base_scality_node_config {
    local conf_has_changed=false
    if [[ -z "$(egrep '^dirsync=0' /etc/biziod/bizobj.disk1)" ]]; then
        echo "dirsync=0" | sudo tee -a /etc/biziod/bizobj.disk1
        conf_has_changed=true
    fi
    if [[ -z "$(egrep '^sync=0' /etc/biziod/bizobj.disk1)" ]]; then
        echo "sync=0" | sudo tee -a /etc/biziod/bizobj.disk1
        conf_has_changed=true
    fi
    if $conf_has_changed; then
        sudo service scality-node restart
    fi
}

function install_base_scality_node {
    distro_dispatch _install_base_scality_node_centos _install_base_scality_node_ubuntu
}


function _create_credentials_file {
    cat > /tmp/scality-installer-credentials <<EOF
{
   "gui":{
       "username":"$SUP_ADMIN_LOGIN",
       "password":"$SUP_ADMIN_PASS"
   },
   "internal-management-requests":{
       "username":"$INTERNAL_MGMT_LOGIN",
       "password":"$INTERNAL_MGMT_PASS"
   }
}
EOF
}

function _how_sould_that_be_called {
    # A full Tempest volume API run needs at least 40G of disk space
    if [[ $(free -m | awk '/Mem:/ {print $2}') -gt 65536 ]]; then
        _prepare_datadir_on_tmpfs
    else
        _prepare_datadir_on_fs
    fi
    sudo touch /scalitytest/disk1/.ok_for_biziod
}

function _scality_node_config {
    # https://docs.scality.com/pages/viewpage.action?pageId=16057344#InstallNodesonCentOS/RedHat-Settingupthepreseedfilefornodeconfiguration
    cat > scality-node-preseed <<EOF
{
    "disks": "1",
    "disk-mapping": null,
    "metadisks": null,
    "prefix": "/scalitytest/disk",
    "name": "node-n",
    "nodes": "1",
    "ip": "$HOST_IP",
    "chord-ip": "$HOST_IP",
    "supervisor-ip": "$HOST_IP",
    "ssl": "0",
    "tier2": false
}
EOF
    local scnc_path=$(which scality-node-config)
    sudo $scnc_path --preseed-file scality-node-preseed
}

function _install_base_scality_node_centos {
    _create_credentials_file
    _how_sould_that_be_called
    _install_dependencies_centos
    install_packages scality-node scality-sagentd scality-nasdk-tools
    _scality_node_config
    _tune_base_scality_node_config
    _configure_sagentd
}

function _configure_nodes_packages_ubuntu {
    # See https://docs.scality.com/display/R43/Install+Nodes+on+Ubuntu#InstallNodesonUbuntu-Configuringthenodes
    echo "scality-node scality-node/meta-disks string" | sudo debconf-set-selections
    echo "scality-node scality-node/set-bizobj-on-ssd boolean false" | sudo debconf-set-selections
    echo "scality-node scality-node/mount-prefix string /scalitytest/disk" | sudo debconf-set-selections
    echo "scality-node scality-node/name-prefix string node-n" | sudo debconf-set-selections
    echo "scality-node scality-node/setup-sagentd boolean true" | sudo debconf-set-selections
    echo "scality-node scality-node/processes-count string 1" | sudo debconf-set-selections
    echo "scality-node scality-node/chord-ip string $HOST_IP" | sudo debconf-set-selections
    echo "scality-node scality-node/node-ip string $HOST_IP" | sudo debconf-set-selections
    echo "scality-node scality-node/biziod-count string  1" | sudo debconf-set-selections
}

function _configure_sagentd {
    sudo sed -i -r '/^agentAddress/d;s/.*rocommunity public  default.*/rocommunity public  default/' /etc/snmp/snmpd.conf
    sudo sed -i 's#/tmp/oidlist.txt#/var/lib/scality-sagentd/oidlist.txt#' /usr/local/scality-sagentd/snmpd_proxy_file.py
    sudo sed -i "/ip_whitelist:/a - $HOST_IP" /etc/sagentd.yaml
    sudo /etc/init.d/scality-sagentd restart
    sudo /etc/init.d/snmpd stop; sleep 2; sudo /etc/init.d/snmpd start
    # Check to see if SNMP is up and running
    snmpwalk -v2c -c public -m+/usr/share/snmp/mibs/scality.mib localhost SNMPv2-SMI::enterprises.37489
}

function _install_base_scality_node_ubuntu {
    # See http://docs.scality.com/display/R43/Setting+Up+Credentials+for+Ring+4.3
    _create_credentials_file
    _how_sould_that_be_called
    _install_dependencies_ubuntu
    _configure_nodes_packages_ubuntu
    install_packages scality-node scality-sagentd scality-nasdk-tools
    _tune_base_scality_node_config
    _configure_sagentd
}

function install_supervisor {
    distro_dispatch install_supervisor_centos install_supervisor_ubuntu
}

function install_supervisor_centos {
    install_packages scality-supervisor
    # Fixme : apache complains about that setup when it starts
    sudo mv /etc/httpd/conf.d/t_scality-supervisor{.conf,.conf.bck}
    sudo service scality-supervisor start
}

function install_supervisor_ubuntu {
    # The following command should automatically enable apache2 mod ssl
    install_packages scality-supervisor
    # For Ubuntu 12 and 14 compatibility, scality-supervisor installs 2 VHost scality-supervisor and scality-supervisor.conf
    if [[ "$(lsb_release -c -s)" == "trusty" ]]; then
        sudo rm -f /etc/apache2/sites-*/scality-supervisor
    else
        sudo rm -f /etc/apache2/sites-*/scality-supervisor.conf
    fi
}

function _configure_ringsh {
    echo "default_config = \
    {   'accessor': None,
        'auth': {   'password': '$INTERNAL_MGMT_PASS', 'user': '$INTERNAL_MGMT_LOGIN'},
        'brs2': None,
        'dsup': {   'url': 'https://$HOST_IP:3443'},
        'key': {   'class1translate': '0'},
        'node': {
            'address': '$HOST_IP',
            'chordPort': 4244,
            'adminPort': '6444',
            'dsoName': 'MyRing'
        },
        'supervisor': {   'url': 'https://$HOST_IP:2443'},
        'supv2': {   'url': 'http://$HOST_IP:12345'}
    }" | sudo tee /usr/local/scality-ringsh/ringsh/config.py >/dev/null
}

function install_ringsh {
    install_packages scality-ringsh
    _configure_ringsh
}

function build_ring {
    echo "supervisor ringCreate MyRing
            supervisor serverAdd server1 $HOST_IP 7084
            supervisor serverList
            sleep 10
            supervisor nodeSetRing MyRing $HOST_IP 8084
            sleep 10
            supervisor nodeJoin $HOST_IP 8084
            sleep 10" | ringsh
}

function show_ring_status {
    echo "supervisor nodeStatus $HOST_IP 8084
            supervisor ringStatus MyRing
            supervisor ringStorage MyRing" | ringsh
}

function install_sproxyd {
    distro_dispatch install_sproxyd_centos install_sproxyd_ubuntu
}

function _configure_sproxyd {
    sudo sed -i -r 's/bstraplist.*/bstraplist": "'$HOST_IP':4244",/;/general/a\        "ring": "MyRing",' /etc/sproxyd.conf

    if [[ $RING_VERSION == 4 ]]; then
        sudo sed -i 's/"alias": "chord"/"alias": "chord_path"/' /etc/sproxyd.conf
        sudo sed -i '/by_path_cos/d;/by_path_service_id/d' /etc/sproxyd.conf
        sudo sed -i '/ring_driver:0/a\        "by_path_cos": 0,' /etc/sproxyd.conf
        sudo sed -i '/ring_driver:0/a\        "by_path_service_id": "0xC0",' /etc/sproxyd.conf

        sudo sed -i '/ring_driver:1/a\        "by_path_cos": 1,' /etc/sproxyd.conf
        sudo sed -i '/ring_driver:1/a\        "by_path_service_id": "0xC1",' /etc/sproxyd.conf

        sudo sed -i '/"by_path_enabled": / { s/"by_path_enabled": false/"by_path_enabled": true/ }' /etc/sproxyd.conf
    else
        # Ring 5 ships with a saner default sproxy.conf which requires less change to support our use cases
        sudo sed -i -r -e 's/"by_path_cos": 3,/"by_path_cos": 0,/' /etc/sproxyd.conf
    fi
}

function _postconfigure_sproxyd {
    sudo /etc/init.d/scality-sproxyd restart
    sudo /usr/local/scality-sagentd/sagentd-manageconf -c /etc/sagentd.yaml add `hostname -s`-sproxyd type=sproxyd ssl=0 port=10000 address=$HOST_IP path=/run/scality/connectors/sproxyd
    sudo /etc/init.d/scality-sagentd restart
}

function install_sproxyd_centos {
    install_packages scality-sproxyd-httpd
    # https://docs.scality.com/display/R43/Install+sproxyd+on+CentOS+or+RedHat
    sudo sed -i "s/^#LoadModule fastcgi_module modules\/mod_fastcgi.so/LoadModule fastcgi_module modules\/mod_fastcgi.so/" /etc/httpd/conf.d/fastcgi.conf
    _configure_sproxyd
    amend_apache_conf /etc/httpd/conf.d
    sudo service httpd restart
    _postconfigure_sproxyd
}

function install_sproxyd_ubuntu {
    install_packages scality-sproxyd-apache2
    # For Ubuntu 12 and 14 compatibility, scality-sd-apache2 installs 2 VHost scality-sd.conf and scality-sd
    if [[ "$(lsb_release -c -s)" == "trusty" ]]; then
        sudo rm -f /etc/apache2/sites-*/scality-sd
    else
        sudo rm -f /etc/apache2/sites-*/scality-sd.conf
    fi
    _configure_sproxyd
    amend_apache_conf /etc/apache2/sites-available
    sudo service apache2 restart
    _postconfigure_sproxyd
}

function amend_apache_conf {
    local conf_file_prefix=$1/scality-sd
    if [[ -z "$(grep LimitRequestLine ${conf_file_prefix}*)" ]]; then
        # See http://svn.xe15.com/trac/ticket/12163
        sudo sed -i "/DocumentRoot/a LimitRequestLine 32766" ${conf_file_prefix}*
        sudo sed -i "/DocumentRoot/a LimitRequestFieldSize 32766" ${conf_file_prefix}*
        sudo sed -i "/DocumentRoot/a AllowEncodedSlashes ${AllowEncodedSlashes}" ${conf_file_prefix}*
        sudo sed -i "/DocumentRoot/a KeepAlive ${KeepAlive}" ${conf_file_prefix}*
    else 
        echo "Could not find any file matching this pattern : ${conf_file_prefix} , exiting."
        return 1
    fi
}


function install_sfused {
    install_packages scality-sfused
    sudo tee /etc/sfused.conf <<EOF
{
    "general": {
        "ring": "MyRing",
        "allowed_rootfs_uid": "1000,122,33"
    },
    "cache:0": {
        "ring_driver": 0,
        "type": "write_through"
    },
    "ring_driver:0": {
        "type": "chord",
        "bstraplist": "$HOST_IP:4244"
    },
    "transport": {
        "type": "fuse",
        "big_writes": 1
    },
    "ino_mode:0": {
        "cache": 0,
        "type": "mem"
    },
    "ino_mode:2": {
        "stripe_cos": 0,
        "cache_md": 0,
        "cache_stripes": 0,
        "type": "sparse",
        "max_data_in_main": 32768
    },
    "ino_mode:3": {
        "cache": 0,
        "type": "mem"
    }
}
EOF

    if [[ $RING_VERSION == 4 ]]; then
        # Ring 5 doesn't support the 'mountpoint' parameter anymore
        sudo sed -i '/"general": /a\        "mountpoint": "/ring/0",' /etc/sfused.conf
    else
        # Ring 5 requires the 'rootfs_cache' parameter to be set (the default is '-1')
        sudo sed -i '/"general": /a\        "rootfs_cache": 0,' /etc/sfused.conf
    fi

    # The following command must be run only once. It touches data on the ring, it does nothing at the connector's side
    sudo sfused -X -c /etc/sfused.conf
    sudo /etc/init.d/scality-sfused restart
    sudo /usr/local/scality-sagentd/sagentd-manageconf -c /etc/sagentd.yaml add `hostname -s`-sfused type=sfused port=7002 address=$HOST_IP path=/run/scality/connectors/sfused
    sudo /etc/init.d/scality-sagentd restart
}

function test_sproxyd {
    # The default alias changed in Ring 5
    if [[ $RING_VERSION == 4 ]]; then
        sproxyd_alias="chord_path arc"
    else
        sproxyd_alias="bpchord bparc"
    fi
    for path in $sproxyd_alias; do
        local r=$RANDOM
        local put_response=${r}_put
        local get_response=${r}_get
        local url="http://localhost:81/proxy/${path}/${r}"
        curl -i -XPUT -H "Expect:" -H "x-scal-usermd: bXl1c2VybWQ=" ${url} --data-binary @/etc/hosts -o $put_response
        cat $put_response
        grep '200 OK' $put_response
        curl -i -XGET ${url} -o $get_response
        cat $get_response
        grep '200 OK' $get_response
        grep "Content-Length: $(stat --printf="%s" /etc/hosts)" $get_response
        for file in $put_response $get_response; do
            if [[ -e $file ]]; then
                rm $file
            fi
        done
    done
}
