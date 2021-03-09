#!/bin/bash -ex

my_file=$(realpath "$0")
my_dir="$(dirname $my_file)"

source ${my_dir}/functions

echo "Workspace is $WORKSPACE"
OPENSHIFT_INSTALL_DIR=${INSTALL_DIR:-"${WORKSPACE}/os-install-config"}
OS_IMAGE_PUBLIC_SERVICE=${OS_IMAGE_PUBLIC_SERVICE:="https://image.public.sjc1.vexxhost.net/"}
OPENSHIFT_VERSION="4.5.21"

export VEXX_NETWORK=${VEXX_NETWORK:-"management"}
export VEXX_SUBNET=${VEXX_SUBNET:-"management"}
export VEXX_GATEWAY=${VEXX_GATEWAY:-"10.0.0.1"}
export VEXX_ROUTER=${VEXX_ROUTER:-"router1"}

sudo yum install -y python3 epel-release
sudo yum install -y jq
sudo pip3 install "cryptography<3.3.2"  python-openstackclient ansible yq jinja2

mkdir -p ${WORKSPACE}/tmpopenshift
pushd ${WORKSPACE}/tmpopenshift
if ! command -v openshift-install; then
  curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_VERSION}/openshift-install-linux-${OPENSHIFT_VERSION}.tar.gz
  tar xzf openshift-install-linux-${OPENSHIFT_VERSION}.tar.gz
  sudo mv ./openshift-install /usr/local/bin
fi
if ! command -v oc || ! command -v kubectl; then
  curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_VERSION}/openshift-client-linux-${OPENSHIFT_VERSION}.tar.gz
  tar xzf openshift-client-linux-${OPENSHIFT_VERSION}.tar.gz
  sudo mv ./oc ./kubectl /usr/local/bin
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
baseDomain: ${KUBERNETES_CLUSTER_NAME}
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

openshift-install --dir $OPENSHIFT_INSTALL_DIR create manifests

rm -f ${OPENSHIFT_INSTALL_DIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml ${OPENSHIFT_INSTALL_DIR}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

if [[ ! -d $WORKSPACE/tf-openshift ]]; then
  git clone https://github.com/tungstenfabric/tf-openshift.git $WORKSPACE/tf-openshift
fi

$WORKSPACE/tf-openshift/scripts/apply_install_manifests.sh $OPENSHIFT_INSTALL_DIR

openshift-install --dir $OPENSHIFT_INSTALL_DIR  create ignition-configs

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
        'verification': {}
    },
    'filesystem': 'root',
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
            'verification': {}
        },
        'filesystem': 'root',
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
      os_network: "${VEXX_NETWORK}"
      os_subnet: "${VEXX_SUBNET}-nodes"
      os_router: "${VEXX_ROUTER}-external-router"
      # Port names
 #     os_port_api: "{{ infraID }}-api-port"
 #     os_port_ingress: "{{ infraID }}-ingress-port"
      os_port_bootstrap: "{{ infraID }}-bootstrap-port"
      os_port_master: "{{ infraID }}-master-port"
      os_port_worker: "{{ infraID }}-worker-port"
      # Security groups names
      os_sg_master: "allow_all"
      os_sg_worker: "allow_all"
      # Server names
 #     os_api_lb_server_name: "{{ infraID }}-api-lb"
 #     os_ing_lb_server_name: "${INFRA_ID}-ing-lb"
      os_bootstrap_server_name: "{{ infraID }}-bootstrap"
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
      os_subnet_range: '10.0.0.0/16'
      os_flavor_master: 'v2-standard-16'
      os_flavor_worker: 'v2-highcpu-16'
      os_image_rhcos: 'rhcos'
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
  - name: 'Create the bootstrap server port'
    os_port:
      name: "{{ os_port_bootstrap }}"
      network: "{{ os_network }}"
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
helper:
  name: "helper"
  ipaddr: "${NODE_IP}"
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
ansible-playbook -e @${WORKSPACE}/helper_vars.env ./tasks/setup_dns.yaml
popd

exit 0

openstack image create --disk-format=raw --container-format=bare --file ${OPENSHIFT_INSTALL_DIR}/bootstrap.ign bootstrap-ignition-image-$INFRA_ID
uri=$(openstack image show bootstrap-ignition-image-$INFRA_ID | grep -oh "/v2/images/.*/file")
storage_url=${OS_IMAGE_PUBLIC_SERVICE}${uri}
token=$(openstack token issue -c id -f value)
ca_sert=$(cat ${OPENSHIFT_INSTALL_DIR}/auth/kubeconfig | yq -r '.clusters[0].cluster["certificate-authority-data"]')
cat <<EOF > $OPENSHIFT_INSTALL_DIR/$INFRA_ID-bootstrap-ignition.json
{
  "ignition": {
    "config": {
      "append": [{
        "source": "${storage_url}",
        "verification": {},
        "httpHeaders": [{
          "name": "X-Auth-Token",
          "value": "${token}"
        }]
      }]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [{
          "source": "data:text/plain;charset=utf-8;base64,${ca_sert}",
          "verification": {}
        }]
      }
    },
    "timeouts": {},
    "version": "2.4.0"
  },
  "networkd": {},
  "passwd": {},
  "storage": {},
  "systemd": {}
}
EOF

for index in $(seq 0 2); do
    MASTER_HOSTNAME="$INFRA_ID-master-$index\n"
    python3 -c "import base64, json, sys;
ignition = json.load(sys.stdin);
files = ignition['storage'].get('files', []);
files.append({'path': '/etc/hostname', 'mode': 420, 'contents': {'source': 'data:text/plain;charset=utf-8;base64,' + base64.standard_b64encode(b'$MASTER_HOSTNAME').decode().strip(), 'verification': {}}, 'filesystem': 'root'});
ignition['storage']['files'] = files;
json.dump(ignition, sys.stdout)" <$OPENSHIFT_INSTALL_DIR/master.ign > "$OPENSHIFT_INSTALL_DIR/$INFRA_ID-master-$index-ignition.json"
done

# SETUP LOAD BALANCERS
cat  <<EOM > ${OPENSHIFT_INSTALL_DIR}/user-data-api.sh
#!/bin/bash

sudo apt update -y
sudo apt install nginx-full -y

cat <<EOF > lb.conf
stream {
    server {
        listen 6443;
        proxy_pass kube_api_backend;
    }
    upstream kube_api_backend {
      server 10.100.0.50:6443;
      server 10.100.0.51:6443;
      server 10.100.0.52:6443;
      server 10.100.0.53:6443;
    }

     server {
        listen 22623;
        proxy_pass machineconfig_backend;
    }
    upstream machineconfig_backend {
      server 10.100.0.50:22623;
      server 10.100.0.51:22623;
      server 10.100.0.52:22623;
      server 10.100.0.53:22623;
    }
}
EOF

sudo mv lb.conf /etc/nginx/modules-enabled
sudo systemctl restart nginx

EOM

openstack server create --security-group allow_all --network ${INFRA_ID}-network --image 338b5153-a173-4d35-abfd-c0aa9eaec1d7 --flavor v2-highcpu-2  --user-data ${OPENSHIFT_INSTALL_DIR}/user-data-api.sh ${INFRA_ID}-api-lb --key itimofeev --boot-from-volume 10
openstack server add floating ip ${INFRA_ID}-api-lb ${OPENSHIFT_API_FIP}

cat  <<EOM > ${OPENSHIFT_INSTALL_DIR}/user-data-ing.sh
#!/bin/bash

sudo apt update -y
sudo apt install nginx-full -y

cat <<EOF > lb.conf
stream {
    server {
        listen 80;
        proxy_pass ing_http_backend;
    }
    upstream ing_http_backend {
      server 10.100.0.60:80;
      server 10.100.0.61:80;
      server 10.100.0.62:80;
    }

    server {
        listen 443;
        proxy_pass ing_https_backend;
    }
    upstream ing_https_backend {
      server 10.100.0.60:443;
      server 10.100.0.61:443;
      server 10.100.0.62:443;
    }
}
EOF

sudo mv lb.conf /etc/nginx/modules-enabled
sudo systemctl restart nginx

EOM

openstack server create --security-group allow_all --network ${INFRA_ID}-network --image 338b5153-a173-4d35-abfd-c0aa9eaec1d7 --flavor v2-highcpu-2  --user-data ${OPENSHIFT_INSTALL_DIR}/user-data-ing.sh ${INFRA_ID}-ing-lb --key itimofeev --boot-from-volume 10
openstack server add floating ip ${INFRA_ID}-ing-lb ${OPENSHIFT_INGRESS_FIP}

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

  - name: 'Create the bootstrap floating IP'
    os_floating_ip:
      state: present
      network: "{{ os_external_network }}"
      server: "{{ os_bootstrap_server_name }}"
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

openshift-install --dir ${OPENSHIFT_INSTALL_DIR} wait-for bootstrap-complete

cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/down-bootstrap.yaml
- import_playbook: common.yaml

- hosts: all
  gather_facts: no

  tasks:
  - name: 'Remove the bootstrap server'
    os_server:
      name: "{{ os_bootstrap_server_name }}"
      state: absent
      delete_fip: yes

  - name: 'Remove the bootstrap server port'
    os_port:
      name: "{{ os_port_bootstrap }}"
      state: absent
EOF

ansible-playbook -i ${OPENSHIFT_INSTALL_DIR}/inventory.yaml ${OPENSHIFT_INSTALL_DIR}/down-bootstrap.yaml

cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/compute-nodes.yaml
- import_playbook: common.yaml

- hosts: all
  gather_facts: no
  tasks:
  - name: 'Create the Compute servers'
    os_server:
      name: "{{ item.1 }}-{{ item.0 }}"
      image: "{{ os_image_rhcos }}"
      flavor: "{{ os_flavor_worker }}"
      volume_size: 25
      boot_from_volume: True
      auto_ip: no
      userdata: "{{ lookup('file', 'worker.ign') | string }}"
      nics:
      - port-name: "{{ os_port_worker }}-{{ item.0 }}"
    with_indexed_items: "{{ [os_compute_server_name] * os_compute_nodes_number }}"
EOF

ansible-playbook -i ${OPENSHIFT_INSTALL_DIR}/inventory.yaml ${OPENSHIFT_INSTALL_DIR}/compute-nodes.yaml

mkdir -p ~/.kube
cp ${OPENSHIFT_INSTALL_DIR}/auth/kubeconfig ~/.kube/config
chmod go-rwx ~/.kube/config

# We have to approve 6 certs totally
count=6
while [[ $count -gt 0 ]]; do
  for cert in $(oc get csr | grep Pending | sed 's/|/ /' | awk '{print $1}'); do
    oc adm certificate approve $cert
    count=$((count-1))
  done
  sleep 3s
done

openshift-install --dir ${OPENSHIFT_INSTALL_DIR}  --log-level debug wait-for install-complete

echo "INFO: Openshift Setup Complete"