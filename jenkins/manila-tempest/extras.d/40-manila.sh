# install phase: Setup bridge
if [[ "$1" == "stack" && "$2" == "install" ]]; then
	sudo ovs-vsctl add-br br-ringnet
fi


# post-config phase: Configure neutron
if [[ "$1" == "stack" && "$2" == "post-config" ]]; then
	iniset /etc/neutron/plugins/ml2/ml2_conf.ini ml2_type_flat flat_networks physnet
	iniset /etc/neutron/plugins/ml2/ml2_conf.ini ovs bridge_mappings physnet:br-ringnet
fi


# extra phase: Create neutron network for tenant use
if [[ "$1" == "stack" && "$2" == "extra" ]]; then
	source ${TOP_DIR}/extras.d/netdef
	neutron net-create ringnet --shared --provider:network_type flat --provider:physical_network physnet
	neutron subnet-create ringnet --allocation-pool ${TENANTS_POOL} --name ringsubnet ${TENANTS_NET}
fi
