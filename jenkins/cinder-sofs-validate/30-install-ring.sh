#!/bin/bash -xue

SUP_ADMIN_LOGIN=myName
SUP_ADMIN_PASS=myPass
INTERNAL_MGMT_LOGIN=super
INTERNAL_MGMT_PASS=adminPass
export DEBIAN_FRONTEND=noninteractive

HOST_IP=$(ip addr show dev eth0 | sed -nr 's/.*inet ([0-9.]+).*/\1/p');

function add_source() {
    # subshell trick, do not output the password to stdout
    (set +x; echo "deb [arch=amd64] http://${SCAL_PASS}@packages.scality.com/stable_khamul/ubuntu/ $(lsb_release -c -s) main" | sudo tee /etc/apt/sources.list.d/scality4.list &>/dev/null)

    # We use 2 alternative methods to add the key because the script can also
    # be used outside of Jenkins context (in a standalone way)
    if ! gpg --keyserver keys.gnupg.net --recv-keys 5B1943DD; then
        sudo apt-key add jenkins/cinder-sofs-validate/scality.gpg
    else
        gpg -a --export 5B1943DD | sudo apt-key add -
    fi

    # snmp-mibs-downloader is a dependency. It is only available in Ubuntu multiverse :
    sudo sed -ri "s/^#\s+(.*multiverse.*)/\1/" /etc/apt/sources.list
    sudo apt-get update
}

function _prepare_datadir_on_tmpfs() {
    sudo mkdir -p /scalitytest/disk1
    # be sure we don't mount multiple times
    if [[ -z "$(mount -l | grep /scalitytest/disk1)" ]]; then
        sudo mount -t tmpfs -o size=60g tmpfs /scalitytest/disk1
    fi
}

function _prepare_datadir_on_fs() {
    sudo mkdir -p /scalitytest/disk1
}

function _install_dependencies() {
    sudo apt-get install --yes debconf-utils snmp
}

function _tune_base_scality_node_config() {
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

function install_base_scality_node() {
    # See http://docs.scality.com/display/R43/Setting+Up+Credentials+for+Ring+4.3
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

    # A full Tempest volume API run needs at least 40G of disk space
    if [[ $(free -m | awk '/Mem:/ {print $2}') -gt 65536 ]]; then
      _prepare_datadir_on_tmpfs
    else
      _prepare_datadir_on_fs
    fi
    sudo touch /scalitytest/disk1/.ok_for_biziod

    _install_dependencies

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
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --yes -q scality-node scality-sagentd scality-nasdk-tools

    _tune_base_scality_node_config

    # Sagentd configuration
    sudo sed -i -r '/^agentAddress/d;s/.*rocommunity public  default.*/rocommunity public  default/' /etc/snmp/snmpd.conf
    sudo sed -i 's#/tmp/oidlist.txt#/var/lib/scality-sagentd/oidlist.txt#' /usr/local/scality-sagentd/snmpd_proxy_file.py
    sudo sed -i "/ip_whitelist:/a - $HOST_IP" /etc/sagentd.yaml
    sudo /etc/init.d/scality-sagentd restart
    sudo /etc/init.d/snmpd stop; sleep 2; sudo /etc/init.d/snmpd start
    
    # Check to see if SNMP is up and running
    snmpwalk -v2c -c public -m+/usr/share/snmp/mibs/scality.mib localhost SNMPv2-SMI::enterprises.37489
}

function install_supervisor() {
    # The following command should automatically enable apache2 mod ssl
    sudo apt-get install --yes scality-supervisor
    # For some reason, scality-supervisor installs 2 VHost scality-supervisor and scality-supervisor.conf
    if [[ -f /etc/apache2/sites-available/scality-supervisor ]]; then
        sudo rm -f /etc/apache2/sites-available/scality-supervisor
    fi
}

function install_ringsh() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --yes -q scality-ringsh
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
        'supervisor': {   'url': 'https://$HOST_IP:2443'}
    }" | sudo tee /usr/local/scality-ringsh/ringsh/config.py >/dev/null
}

function build_ring() {
    echo "supervisor ringCreate MyRing
          supervisor serverAdd server1 $HOST_IP 7084
          supervisor serverList
          sleep 10
          supervisor nodeSetRing MyRing $HOST_IP 8084
          sleep 10
          supervisor nodeJoin $HOST_IP 8084
          sleep 10" | ringsh
}

function show_ring_status() {
    echo "supervisor nodeStatus $HOST_IP 8084
          supervisor ringStatus MyRing
          supervisor ringStorage MyRing" | ringsh
}

function install_sproxyd() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get install --yes -q scality-sproxyd-apache2
    sudo sed -i -r 's/bstraplist.*/bstraplist": "'$HOST_IP':4244",/;/general/a\        "ring": "MyRing",' /etc/sproxyd.conf
    sudo sed -i 's/"alias": "chord"/"alias": "chord_path"/' /etc/sproxyd.conf
    sudo sed -i '/by_path_cos/d;/by_path_service_id/d' /etc/sproxyd.conf
    sudo sed -i '/ring_driver:0/a\        "by_path_cos": 0,' /etc/sproxyd.conf
    sudo sed -i '/ring_driver:0/a\        "by_path_service_id": "0xC0",' /etc/sproxyd.conf
    # The next line needs the Chord ring driver to be defined first, ie before the Arc ring driver.
    sudo sed -i '0,/"by_path_enabled": / { s/"by_path_enabled": false/"by_path_enabled": true/ }' /etc/sproxyd.conf

    # For some reason, scality-sd-apache2 installs 2 VHost scality-sd.conf and scality-sd
    if [[ -f /etc/apache2/sites-available/scality-sd ]]; then
        sudo rm -f /etc/apache2/sites-available/scality-sd
    fi

    if [[ -z "$(grep LimitRequestLine /etc/apache2/sites-available/scality-sd.conf)" ]]; then
      # See http://svn.xe15.com/trac/ticket/12163
      sudo sed -i "/DocumentRoot/a LimitRequestLine 32766" /etc/apache2/sites-available/scality-sd.conf
      sudo sed -i "/DocumentRoot/a LimitRequestFieldSize 32766" /etc/apache2/sites-available/scality-sd.conf
      sudo service apache2 restart
    fi

    sudo /etc/init.d/scality-sproxyd restart
    sudo /usr/local/scality-sagentd/sagentd-manageconf -c /etc/sagentd.yaml add `hostname -s`-sproxyd type=sproxyd ssl=0 port=10000 address=$HOST_IP path=/run/scality/connectors/sproxyd
    sudo /etc/init.d/scality-sagentd restart
}

function install_sfused() {
    sudo apt-get install --yes scality-sfused
    sudo tee /etc/sfused.conf <<EOF
{
    "general": {
        "mountpoint": "/ring/0",
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
    if [[ -z "$(grep max_data_in_main /etc/sfused.conf)" ]]; then
        sed -i '/"type": "sparse"/a\        "max_data_in_main": 128768,' /etc/sfused.conf
    fi
    # The following command must be run only once. It touches data on the ring, it does nothing at the connector's side
    sudo sfused -X -c /etc/sfused.conf
    sudo /etc/init.d/scality-sfused restart
    sudo /usr/local/scality-sagentd/sagentd-manageconf -c /etc/sagentd.yaml add `hostname -s`-sfused type=sfused port=7002 address=$HOST_IP path=/run/scality/connectors/sfused
    sudo /etc/init.d/scality-sagentd restart
}

function _configure_dewpoint() {
    # See http://svn.xe15.com/trac/ticket/12839
    if [[ $(lsb_release -c -s) == "trusty" ]]; then
        sudo a2dismod mpm_event
        sudo a2enmod mpm_worker
        sudo sed -i '/StartServers/d;/ServerLimit/d' /etc/apache2/mods-available/mpm_worker.conf
        sudo sed -i '/<IfModule mpm_worker_module>/a\        StartServers             1' /etc/apache2/mods-available/mpm_worker.conf
        sudo sed -i '/<IfModule mpm_worker_module>/a\        ServerLimit              1' /etc/apache2/mods-available/mpm_worker.conf
    fi
    # On Ubuntu Precise, the packaging of libapache2-scality-mod-dewpoint does the thing correctly
}

function install_dewpoint() {
    sudo apt-get install --yes libapache2-scality-mod-dewpoint

    if [[ -z "$(mount | grep '/dev/fuse on /ring/0\.')" ]]; then
        echo "A SOFS filesystem must be properly mounted on /ring/0 in order to configure Dewpoint. Exiting now."
        return 1
    fi

    if ! $(sudo test -e /ring/0/cdmi); then
        sudo mkdir /ring/0/cdmi;
    fi

    sudo tee /etc/apache2/sites-available/dewpoint.conf <<EOF
Listen 82
<VirtualHost *:82>
    <Location />
        SetHandler dewpoint_module
    </Location>
    LogLevel debug
    ErrorLog \${APACHE_LOG_DIR}/dewpoint_error.log
    CustomLog \${APACHE_LOG_DIR}/dewpoint_access.log combined
</VirtualHost>
EOF
    sudo truncate -s 0 /etc/apache2/mods-available/dewpoint.conf
    sudo a2ensite dewpoint.conf

    _configure_dewpoint
    sudo service apache2 restart
}

function test_dewpoint() {
    for i in {1..250}; do
        echo $i;
        r=$RANDOM; curl -X PUT http://localhost:82/cdmi/$r --data "@/etc/hosts"; curl http://localhost:82/cdmi/$r
    done
    sudo rm -rf randomdata; sudo dd if=/dev/vda bs=1M count=64 of=randomdata; curl -X POST -v --data-binary @"randomdata" http://localhost:82/cdmi/$RANDOM
}

function purge_ring() {
    cd ~ ; sudo /etc/init.d/scality-sfused stop; sudo /etc/init.d/scality-sproxyd stop; sudo service apache2 stop; sudo /etc/init.d/scality-node stop
    sudo rm -rf /scality*/disk*/* ; sudo find /var/log/scality-* -mtime +14 -delete
    sudo /etc/init.d/scality-node start && sleep 10
    echo "supervisor nodeJoin $(ifconfig eth0 | sed -nr "s/.*inet addr:([0-9.]+).*/\1/p") 8084" | ringsh && sleep 10
    if [[ -n "$(ringsh 'supervisor ringStatus MyRing' | grep 'State: RUN')" ]]; then
        sudo /etc/init.d/scality-sproxyd start ; sudo sfused -X -c /etc/sfused.conf; sudo /etc/init.d/scality-sfused start ; sudo mkdir /ring/0/cdmi; sudo service apache2 restart
    fi
}

function test_sproxyd() {
    r=$RANDOM
    curl -v -XPUT -H "Expect:" -H "x-scal-usermd: bXl1c2VybWQ=" http://localhost:81/proxy/chord_path/$r --data-binary @/etc/hosts
    curl -v -XGET http://localhost:81/proxy/chord_path/$r
}

function install_srb_module() {
    if [[ "$(lsb_release -c -s)" != "trusty" ]]; then
        echo "SRB is only compatible with a recent version of Ubuntu"
        return 1
    fi
    sudo apt-get install --yes lvm2 git build-essential thin-provisioning-tools;
    if [[ ! -d ~/RestBlockDriver ]]; then
        cd ~ && git clone https://github.com/scality/RestBlockDriver.git
    fi
    cd ~/RestBlockDriver && make && sudo insmod ~/RestBlockDriver/srb.ko
    if [[ -z "$(grep srb /etc/lvm/lvm.conf)" ]]; then
        sudo sed -i '/devices {/a\    types = [ "srb", 16 ]' /etc/lvm/lvm.conf;
    fi
}

function test_srb_on_dewpoint() {
    if [[ ! -d /sys/class/srb/ ]]; then
        echo "The SRB kernel module is not loaded"
        return 1
    fi
    url=http://127.0.0.1:82/cdmi
    echo "$url" | sudo tee /sys/class/srb/add_urls
    echo "jordanvolume 1G" | sudo tee /sys/class/srb/create
    echo "jordanvolume srb0" | sudo tee /sys/class/srb/attach
    sudo mkfs.ext4 /dev/srb0 && sudo mount /dev/srb0 /mnt
    sudo sync && echo 3 | sudo tee /proc/sys/vm/drop_caches && sudo dd if=/dev/zero of=/mnt/test bs=1M count=10 conv=fsync
    cd / && sudo umount /mnt
    echo "srb0" | sudo tee /sys/class/srb/detach
    echo "jordanvolume" | sudo tee /sys/class/srb/destroy
    echo "$url" | sudo tee /sys/class/srb/remove_urls
}


add_source
install_base_scality_node
install_supervisor
install_ringsh
build_ring
show_ring_status
install_sproxyd
install_sfused
