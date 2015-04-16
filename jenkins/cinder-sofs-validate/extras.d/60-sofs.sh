# sofs.sh - DevStack extras script

if [[ "$1" == "stack" && "$2" == "post-config" ]]; then
    if is_service_enabled nova; then
        echo_summary "Configuring Nova for Scality SOFS"
        iniset $NOVA_CONF libvirt scality_sofs_mount_point /sofs
        iniset $NOVA_CONF libvirt scality_sofs_config /etc/sfused.conf

        install_package python-memcache
        iniset $NOVA_CONF DEFAULT servicegroup_driver mc
        iniset $NOVA_CONF DEFAULT memcached_servers 127.0.0.1:11211
   fi
fi
