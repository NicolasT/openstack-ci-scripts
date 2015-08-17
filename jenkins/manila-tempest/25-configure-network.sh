#!/bin/bash -xue
# This configures two networks:
#
# - RING_EXPORTS_NET, where ring management host is exposing its shares
# - TENANTS_NET, where tenants of the devstack install can be attached
#
# A GRE tunnel is setup over the openstack lab (private) tenant network to
# provide routing between these network segments.

# Source network definition
source devstack/extras.d/netdef

# Attach an IP to the bridge added in devstack hooks
sudo ip addr add ${TENANTS_BR} dev br-ringnet

# Configure the network on the manila ring management host
DEVSTACK_NODE=$(/sbin/ip addr show dev eth0 | sed -nr 's/.*inet ([0-9.]+).*/\1/p');
RING_MANAGEMENT_NODE=${JCLOUDS_IPS}

ssh ${RING_MANAGEMENT_NODE} /bin/bash -xue << EOF
sudo ip tunnel add ringnet mode gre remote ${DEVSTACK_NODE} local ${RING_MANAGEMENT_NODE} ttl 255
sudo ip link set ringnet up
sudo ip addr add ${RING_EXPORTS_GW}/24 dev ringnet
sudo ip route add ${TENANTS_NET} dev ringnet
EOF

# Configure the devstack tenant network
sudo ip tunnel add ringnet mode gre remote ${RING_MANAGEMENT_NODE} local ${DEVSTACK_NODE} ttl 255
sudo ip link set ringnet up
sudo ip addr add ${TENANTS_GW}/24 dev ringnet
sudo ip route add ${RING_EXPORTS_NET} dev ringnet

# Verify tunnel connectivity
ping -c 1 ${RING_EXPORTS_GW}
