#!/bin/bash -ex

my_file=$(realpath "$0")
my_dir="$(dirname $my_file)"

source ${my_dir}/functions

echo "Workspace is $WORKSPACE"

export KUBERNETES_CLUSTER_NAME=${KUBERNETES_CLUSTER_NAME:-"test1"}
export KUBERNETES_CLUSTER_DOMAIN=${KUBERNETES_CLUSTER_DOMAIN:-"example.com"}
export INSTALL_DIR=${INSTALL_DIR:-"${WORKSPACE}/install-${KUBERNETES_CLUSTER_NAME}"}

OPENSHIFT_INSTALL_DIR=${INSTALL_DIR}
OS_IMAGE_PUBLIC_SERVICE=${OS_IMAGE_PUBLIC_SERVICE:="https://image.public.sjc1.vexxhost.net/"}
OPENSHIFT_VERSION="4.6.20"

export VEXX_NETWORK=${VEXX_NETWORK:-"management"}
export VEXX_ROUTER=${VEXX_ROUTER:-"router1"}
export HELPER_IP="10.113.0.20"

sudo yum install -y python3 epel-release
sudo yum install -y jq
sudo pip3 install "cryptography<3.3.2"  python-openstackclient ansible yq jinja2

mkdir -p ${WORKSPACE}/tmpopenshift
pushd ${WORKSPACE}/tmpopenshift
if ! -v $WORKSPACE/openshift-install; then
  curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_VERSION}/openshift-install-linux-${OPENSHIFT_VERSION}.tar.gz
  tar xzf openshift-install-linux-${OPENSHIFT_VERSION}.tar.gz
  mv ./openshift-install $WORKSPACE
fi
if ! -f $WORKSPACE/oc; then
  curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_VERSION}/openshift-client-linux-${OPENSHIFT_VERSION}.tar.gz
  tar xzf openshift-client-linux-${OPENSHIFT_VERSION}.tar.gz
  mv ./oc ./kubectl $WORKSPACE
fi
popd
rm -rf ${WORKSPACE}/tmpopenshift

if [[ -z ${OPENSHIFT_PULL_SECRET} ]]; then
  echo "ERROR: set OPENSHIFT_PULL_SECRET env variable"
  exit 1
fi

export OPENSHIFT_PUB_KEY="$(cat ~/.ssh/id_rsa.pub)"

rm -rf $OPENSHIFT_INSTALL_DIR
mkdir -p $OPENSHIFT_INSTALL_DIR

cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/install-config.yaml
apiVersion: v1
baseDomain: ${KUBERNETES_CLUSTER_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 0
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3
metadata:
  creationTimestamp: null
  name: ${KUBERNETES_CLUSTER_NAME}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: Contrail
  serviceNetwork:
  - 172.30.0.0/16
platform:
  none: {}
fips: false
pullSecret: |
  ${OPENSHIFT_PULL_SECRET}
sshKey: |
  ${OPENSHIFT_PUB_KEY}
EOF

$WORKSPACE/openshift-install --dir $OPENSHIFT_INSTALL_DIR create manifests

rm -f ${OPENSHIFT_INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml ${OPENSHIFT_INSTALL_DIR}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

if [[ ! -d $WORKSPACE/tf-openshift ]]; then
  git clone https://github.com/tungstenfabric/tf-openshift.git $WORKSPACE/tf-openshift
fi

$WORKSPACE/tf-openshift/scripts/apply_install_manifests.sh $OPENSHIFT_INSTALL_DIR

$WORKSPACE/openshift-install --dir $OPENSHIFT_INSTALL_DIR  create ignition-configs

export INFRA_ID=$(jq -r .infraID $OPENSHIFT_INSTALL_DIR/metadata.json)

cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/setup_bootsrap_ign.py
import base64
import json
import os

with open('${OPENSHIFT_INSTALL_DIR}/bootstrap.ign', 'r') as f:
    ignition = json.load(f)

files = ignition['storage'].get('files', [])

infra_id = os.environ.get('INFRA_ID', 'openshift').encode()
hostname_b64 = base64.standard_b64encode(infra_id + b'-bootstrap\n').decode().strip()
files.append(
{
    'path': '/etc/hostname',
    'mode': 420,
    'contents': {
        'source': 'data:text/plain;charset=utf-8;base64,' + hostname_b64,
    },
})

ca_cert_path = os.environ.get('OS_CACERT', '')
if ca_cert_path:
    with open(ca_cert_path, 'r') as f:
        ca_cert = f.read().encode()
        ca_cert_b64 = base64.standard_b64encode(ca_cert).decode().strip()

    files.append(
    {
        'path': '/opt/openshift/tls/cloud-ca-cert.pem',
        'mode': 420,
        'contents': {
            'source': 'data:text/plain;charset=utf-8;base64,' + ca_cert_b64,
        },
    })

ignition['storage']['files'] = files;

with open('${OPENSHIFT_INSTALL_DIR}/bootstrap.ign', 'w') as f:
    json.dump(ignition, f)
EOF

cat <<EOF > $OPENSHIFT_INSTALL_DIR/common.yaml
- hosts: localhost
  gather_facts: no

  vars_files:
  - metadata.json

  tasks:
  - name: 'Compute resource names'
    set_fact:
      cluster_id_tag: "openshiftClusterID={{ infraID }}"
      os_network: "{{ infraID }}-network"
      os_subnet: "{{ infraID }}-nodes"
      os_router: "${VEXX_ROUTER}"
      # Port names
      master_addresses:
      - "10.113.0.50"
      - "10.113.0.51"
      - "10.113.0.52"
      worker_addresses:
      - "10.113.0.60"
      - "10.113.0.61"
      - "10.113.0.62"
      bootstrap_address: "10.113.0.21"
      helper_address: "${HELPER_IP}"
      os_port_helper: "{{ infraID }}-helper-port"
      os_port_bootstrap: "{{ infraID }}-bootstrap-port"
      os_port_master: "{{ infraID }}-master-port"
      os_port_worker: "{{ infraID }}-worker-port"
      # Security groups names
      os_sg_master: "allow_all"
      os_sg_worker: "allow_all"
      # Server names
      os_bootstrap_server_name: "{{ infraID }}-bootstrap"
      os_helper_server_name: "{{ infraID }}-helper"
      os_cp_server_name: "{{ infraID }}-master"
      os_cp_server_group_name: "{{ infraID }}-master"
      os_compute_server_name: "{{ infraID }}-worker"

      # Ignition files
      os_bootstrap_ignition: "{{ infraID }}-bootstrap-ignition.json"
EOF

cat <<EOF > $OPENSHIFT_INSTALL_DIR/inventory.yaml
all:
  hosts:
    localhost:
      ansible_connection: local
      ansible_python_interpreter: "{{ansible_playbook_python}}"

      # User-provided values
      os_subnet_range: '10.113.0.0/16'
      os_flavor_master: 'v2-standard-8'
      os_flavor_worker: 'v2-highcpu-16'
      os_flavor_helper: 'v2-standard-2'
      os_image_rhcos: 'rhcos-4.6.8'
      os_image_centos: '60e3bf6d-4c38-427d-8419-9211c5dd763d'
      os_external_network: 'public'
      # OpenShift API floating IP address
      os_api_fip: '${OPENSHIFT_API_FIP}'
      # OpenShift Ingress floating IP address
      os_ingress_fip: '${OPENSHIFT_INGRESS_FIP}'
      # Service subnet cidr
      svc_subnet_range: '172.30.0.0/16'
      os_svc_network_range: '172.30.0.0/15'
      # Subnet pool prefixes
      cluster_network_cidrs: '10.128.0.0/14'
      # Subnet pool prefix length
      host_prefix: '23'
      # Name of the SDN.
      os_networking_type: 'Contrail'

      # Number of provisioned Control Plane nodes
      # 3 is the minimum number for a fully-functional cluster.
      os_cp_nodes_number: 3

      # Number of provisioned Compute nodes.
      # 3 is the minimum number for a fully-functional cluster.
      os_compute_nodes_number: 2
EOF



cat <<EOF >$OPENSHIFT_INSTALL_DIR/network.yaml
# Required Python packages:
#
# ansible
# openstackclient
# openstacksdk
# netaddr
- import_playbook: common.yaml
- hosts: all
  gather_facts: no
  tasks:

  tasks:
  - name: 'Create the cluster network'
    os_network:
      name: "{{ os_network }}"
  - name: 'Set the cluster network tag'
    command:
      cmd: "openstack network set --tag {{ cluster_id_tag }} {{ os_network }}"
  - name: 'Create a subnet'
    os_subnet:
      dns_nameservers:
       - "{{ helper_address }}"
       - 8.8.8.8
      name: "{{ os_subnet }}"
      network_name: "{{ os_network }}"
      cidr: "{{ os_subnet_range }}"
      allocation_pool_start: "{{ os_subnet_range | next_nth_usable(10) }}"
      allocation_pool_end: "{{ os_subnet_range | ipaddr('last_usable') }}"
# If remove thist pause we will have an error due to openstack API unavailable
  - name: Pause for 3 second
    pause:
      seconds: 5
  - name: 'Attach subnet to router'
    command:
      cmd: "openstack router add subnet router1 ${INFRA_ID}-nodes"
EOF

ansible-playbook -vv -i ${OPENSHIFT_INSTALL_DIR}/inventory.yaml ${OPENSHIFT_INSTALL_DIR}/network.yaml


cat <<EOF > $OPENSHIFT_INSTALL_DIR/ports.yaml
# Required Python packages:
#
# ansible
# openstackclient
# openstacksdk
# netaddr

- import_playbook: common.yaml

- hosts: all
  gather_facts: no

  tasks:
  - name: 'Create the helper server port'
    os_port:
      name: "{{ os_port_helper }}"
      network: "{{ os_network }}"
      fixed_ips:
        - ip_address: "{{ helper_address }}"
      security_groups:
      - "{{ os_sg_master }}"

  - name: 'Set helper port tag'
    command:
      cmd: "openstack port set --tag {{ cluster_id_tag }} {{ os_port_helper }}"

  - name: 'Disable helper port security'
    command:
      cmd: "openstack port set --no-security-group --disable-port-security {{ os_port_helper }}"

  - name: 'Create the bootstrap server port'
    os_port:
      name: "{{ os_port_bootstrap }}"
      network: "{{ os_network }}"
      fixed_ips:
        - ip_address: "{{ bootstrap_address }}"
      security_groups:
      - "{{ os_sg_master }}"

  - name: 'Set bootstrap port tag'
    command:
      cmd: "openstack port set --tag {{ cluster_id_tag }} {{ os_port_bootstrap }}"

  - name: 'Disable bootstrap port security'
    command:
      cmd: "openstack port set --no-security-group --disable-port-security {{ os_port_bootstrap }}"

  - name: 'Create the Control Plane ports'
    os_port:
      name: "{{ item.1 }}-{{ item.0 }}"
      network: "{{ os_network }}"
      fixed_ips:
      - ip_address: "{{ master_addresses[item.0] }}"
      security_groups:
      - "{{ os_sg_master }}"
    with_indexed_items: "{{ [os_port_master] * os_cp_nodes_number }}"
    register: ports

  - name: 'Set Control Plane ports tag'
    command:
      cmd: "openstack port set --tag {{ cluster_id_tag }} {{ item.1 }}-{{ item.0 }}"
    with_indexed_items: "{{ [os_port_master] * os_cp_nodes_number }}"

  - name: 'Disable control plane port security'
    command:
      cmd: "openstack port set --no-security-group --disable-port-security {{ item.1 }}-{{ item.0 }}"
    with_indexed_items: "{{ [os_port_master] * os_cp_nodes_number }}"

  - name: 'Create the Compute ports'
    os_port:
      name: "{{ item.1 }}-{{ item.0 }}"
      network: "{{ os_network }}"
      fixed_ips:
      - ip_address: "{{ worker_addresses[item.0] }}"
      security_groups:
      - "{{ os_sg_worker }}"
    with_indexed_items: "{{ [os_port_worker] * os_compute_nodes_number }}"
    register: ports

  - name: 'Set compute ports tag'
    command:
      cmd: "openstack port set --tag {{ cluster_id_tag }} {{ item.1 }}-{{ item.0 }}"
    with_indexed_items: "{{ [os_port_worker] * os_compute_nodes_number }}"

  - name: 'Disable compute port security'
    command:
      cmd: "openstack port set --no-security-group --disable-port-security {{ item.1 }}-{{ item.0 }}"
    with_indexed_items: "{{ [os_port_master] * os_compute_nodes_number}}"

EOF

ansible-playbook -vv -i ${OPENSHIFT_INSTALL_DIR}/inventory.yaml ${OPENSHIFT_INSTALL_DIR}/ports.yaml

# Create helper node

cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/helper.yaml
- import_playbook: common.yaml

- hosts: all
  gather_facts: no

  tasks:
  - name: 'Create the helper server'
    os_server:
      name: "{{ os_helper_server_name }}"
      image: "{{ os_image_centos }}"
      flavor: "{{ os_flavor_helper }}"
      volume_size: 25
      boot_from_volume: True
      auto_ip: no
      key_name: "plab"
      nics:
      - port-name: "{{ os_port_helper }}"

  - name: 'Wait 180 seconds for port 22'
    wait_for:
      port: 22
      host: "{{ helper_address }}"
      delay: 3

EOF

ansible-playbook -vv -i ${OPENSHIFT_INSTALL_DIR}/inventory.yaml ${OPENSHIFT_INSTALL_DIR}/helper.yaml

# Setup helper node
addrs=$(openstack port list -c name -c fixed_ips -f json --tags openshiftClusterID=${INFRA_ID})

declare -a master_ips worker_ips

for i in {0..2}; do
  server="$INFRA_ID-master-port-${i}"
  master_ips[${i}]=$(echo "$addrs" | jq -r --arg server "$server"  '.[] | select(.Name == $server) | .["Fixed IP Addresses"][0]["ip_address"]' )
done

for i in {0..1}; do
  server="$INFRA_ID-worker-port-${i}"
  worker_ips[${i}]=$(echo "$addrs" | jq -r --arg server "$server"  '.[] | select(.Name == $server) | .["Fixed IP Addresses"][0]["ip_address"]' )
done

server="$INFRA_ID-bootstrap-port"
bootstrap_ip=$(echo "$addrs" | jq -r --arg server "$server"  '.[] | select(.Name == $server) | .["Fixed IP Addresses"][0]["ip_address"]' )

cat <<EOF > ${WORKSPACE}/helper_vars.env
---
disk: vda
install_dir: "${OPENSHIFT_INSTALL_DIR}"
helper:
  name: "helper"
  ipaddr: "${HELPER_IP}"
dns:
  domain: "${KUBERNETES_CLUSTER_DOMAIN}"
  clusterid: "${KUBERNETES_CLUSTER_NAME}"
  forwarder1: "8.8.8.8"
  forwarder2: "8.8.4.4"
bootstrap:
  name: "bootstrap"
  ipaddr: "${bootstrap_ip}"
masters:
  - name: "master0"
    ipaddr: "${master_ips[0]}"
  - name: "master1"
    ipaddr: "${master_ips[1]}"
  - name: "master2"
    ipaddr: "${master_ips[2]}"
workers:
  - name: "worker0"
    ipaddr: "${worker_ips[0]}"
  - name: "worker1"
    ipaddr: "${worker_ips[1]}"
EOF

pushd ${my_dir}
ansible-playbook --become -e @${WORKSPACE}/helper_vars.env ./tasks/setup_dns.yaml
ansible-playbook --become -e @${WORKSPACE}/helper_vars.env ./tasks/setup_httpd.yaml
ansible-playbook --become -e @${WORKSPACE}/helper_vars.env ./tasks/setup_haproxy.yaml
popd

bootstrap_ignition_url="http://${HELPER_IP}:8080/ignition/bootstrap.ign"
default_gate=$(ip r | awk '/default/{print $3}')
ca_sert=$(cat ${OPENSHIFT_INSTALL_DIR}/auth/kubeconfig | yq -r '.clusters[0].cluster["certificate-authority-data"]')
cat <<EOF > $OPENSHIFT_INSTALL_DIR/$INFRA_ID-bootstrap-ignition.json
{
  "ignition": {
    "config": {
      "merge": [{
        "source": "${bootstrap_ignition_url}",
      }]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [{
          "source": "data:text/plain;charset=utf-8;base64,${ca_sert}",
        }]
      }
    },
    "version": "3.1.0"
  },
}
EOF

cat <<EOF > $OPENSHIFT_INSTALL_DIR/bootstrap.yaml
# Required Python packages:
#
# ansible
# openstackclient
# openstacksdk
# netaddr

- import_playbook: common.yaml

- hosts: all
  gather_facts: no

  tasks:
  - name: 'Create the bootstrap server'
    os_server:
      name: "{{ os_bootstrap_server_name }}"
      image: "{{ os_image_rhcos }}"
      flavor: "{{ os_flavor_master }}"
      volume_size: 25
      boot_from_volume: True
      userdata: "{{ lookup('file', os_bootstrap_ignition) | string }}"
      auto_ip: no
      nics:
      - port-name: "{{ os_port_bootstrap }}"
EOF

ansible-playbook -i ${OPENSHIFT_INSTALL_DIR}/inventory.yaml ${OPENSHIFT_INSTALL_DIR}/bootstrap.yaml

for index in $(seq 0 2); do
    MASTER_HOSTNAME="$INFRA_ID-master-$index\n"
    python3 -c "import base64, json, sys;
ignition = json.load(sys.stdin);
storage = ignition.get('storage', {});
files.append({'path': '/etc/hostname', 'mode': 420, 'contents': {'source': 'data:text/plain;charset=utf-8;base64,' + base64.standard_b64encode(b'$MASTER_HOSTNAME').decode().strip(), 'verification': {}}, 'filesystem': 'root'});
storage['files'] = files;
ignition['storage'] = storage
json.dump(ignition, sys.stdout)" <$OPENSHIFT_INSTALL_DIR/master.ign > "$OPENSHIFT_INSTALL_DIR/$INFRA_ID-master-$index-ignition.json"
done

cat <<EOF > $OPENSHIFT_INSTALL_DIR/servers.yaml
# Required Python packages:
#
# ansible
# openstackclient
# openstacksdk
# netaddr

- import_playbook: common.yaml

- hosts: all
  gather_facts: no

  tasks:
  - name: 'List the Server groups'
    command:
      cmd: "openstack server group list -f json -c ID -c Name"
    register: server_group_list

  - name: 'Parse the Server group ID from existing'
    set_fact:
      server_group_id: "{{ (server_group_list.stdout | from_json | json_query(list_query) | first).ID }}"
    vars:
      list_query: "[?Name=='{{ os_cp_server_group_name }}']"
    when:
    - "os_cp_server_group_name|string in server_group_list.stdout"

  - name: 'Create the Control Plane server group'
    command:
      cmd: "openstack --os-compute-api-version=2.15 server group create -f json -c id --policy=soft-anti-affinity {{ os_cp_server_group_name }}"
    register: server_group_created
    when:
    - server_group_id is not defined

  - name: 'Parse the Server group ID from creation'
    set_fact:
      server_group_id: "{{ (server_group_created.stdout | from_json).id }}"
    when:
    - server_group_id is not defined

  - name: 'Create the Control Plane servers'
    os_server:
      name: "{{ item.1 }}-{{ item.0 }}"
      image: "{{ os_image_rhcos }}"
      flavor: "{{ os_flavor_master }}"
      volume_size: 25
      boot_from_volume: True
      auto_ip: no
      # The ignition filename will be concatenated with the Control Plane node
      # name and its 0-indexed serial number.
      # In this case, the first node will look for this filename:
      #    "{{ infraID }}-master-0-ignition.json"
      userdata: "{{ lookup('file', [item.1, item.0, 'ignition.json'] | join('-')) | string }}"
      nics:
      - port-name: "{{ os_port_master }}-{{ item.0 }}"
      scheduler_hints:
        group: "{{ server_group_id }}"
    with_indexed_items: "{{ [os_cp_server_name] * os_cp_nodes_number }}"
EOF

ansible-playbook -i ${OPENSHIFT_INSTALL_DIR}/inventory.yaml ${OPENSHIFT_INSTALL_DIR}/servers.yaml
