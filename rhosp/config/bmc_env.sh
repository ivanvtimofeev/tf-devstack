#!/bin/bash

export overcloud_virt_type="kvm"
export domain="lab1.local"
export undercloud_instance="undercloud"
export prov_inspection_iprange="192.168.24.51,192.168.24.91"
export prov_dhcp_start="192.168.24.100"
export prov_dhcp_end="192.168.24.200"
export prov_ip="192.168.24.1"
export prov_subnet_len="24"
export prov_cidr="192.168.24.0/${prov_subnet_len}"
export prov_ip_cidr="${prov_ip}/${prov_subnet_len}"
export fixed_vip="192.168.24.250"

# Interfaces for providing tests run (need only if network isolation enabled)
export internal_vlan="vlan710"
export internal_interface="eth1"
export internal_ip_addr="10.1.0.5"
export internal_net_mask="255.255.255.0"

export external_vlan="vlan720"
export external_interface="eth1"
export external_ip_addr="10.2.0.5"
export external_net_mask="255.255.255.0"

export tenant_ip_net="10.0.0.0/24"

# TODO: rework after AGENT_NODES, CONTROLLER_NODES be used as an input for rhosp
export overcloud_cont_instance="1,2,3"
export overcloud_ctrlcont_instance="1,2,3"
export overcloud_compute_instance="1"
export overcloud_dpdk_instance="1"
export overcloud_sriov_instance="1"
export overcloud_ceph_instance="1,2,3"

# to allow nova to use hp as well (2 are used by vrouter)
export vrouter_huge_pages_1g='32'

#SRIOV parameters
export sriov_physical_interface="ens2f3"
export sriov_physical_network="sriov1"
export sriov_vf_number="4"

# IPA params
export ipa_instance="ipa"
#export ipa_mgmt_ip="$ipa_mgmt_ip" - defined outside
export ipa_prov_ip="192.168.24.5"
