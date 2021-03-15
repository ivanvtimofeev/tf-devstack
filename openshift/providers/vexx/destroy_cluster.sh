#!/bin/bash -ex

my_file=$(realpath "$0")
my_dir="$(dirname $my_file)"

source ${my_dir}/functions

[[ -n "${WORKSPACE}" ]] || err "Setup workspace"

export KUBERNETES_CLUSTER_DOMAIN=${KUBERNETES_CLUSTER_DOMAIN:-"example.com"}
export KUBERNETES_CLUSTER_NAME=${KUBERNETES_CLUSTER_NAME:-"test1"}
export INSTALL_DIR=${INSTALL_DIR:-"${WORKSPACE}/install-${KUBERNETES_CLUSTER_NAME}"}
export OPENSHIFT_INSTALL_DIR=${INSTALL_DIR:-"os-install-config"}

export INFRA_ID=$(jq -r .infraID $OPENSHIFT_INSTALL_DIR/metadata.json)
if [[ -z "${INFRA_ID}" ]]; then
  echo "ERROR: Something get wrong. You INFRA_ID has not been set up"
  exit 1
fi

if [[ ! -f $OPENSHIFT_INSTALL_DIR/inventory.yaml || ! -f $OPENSHIFT_INSTALL_DIR/common.yaml ]]; then
  echo "INFO: Files inventory.yaml or common.yaml can't be found. It looks like nothing to delete"
  exit 0
fi

if [[  "$(openstack port list | grep "10.113.0.1'" | wc -l)" != 0 ]]; then
  openstack router remove subnet router1 ${INFRA_ID}-nodes
fi


if [[ -f ${OPENSHIFT_INSTALL_DIR}/bootstrap.yaml ]]; then
  cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/destroy-bootstrap.yaml
- import_playbook: common.yaml
- hosts: all
  gather_facts: no
  tasks:
  - name: 'Delete Compute servers'
    os_server:
      name: "{{ os_bootstrap_server_name }}"
      state: absent
EOF
    ansible-playbook -i $OPENSHIFT_INSTALL_DIR/inventory.yaml $OPENSHIFT_INSTALL_DIR/destroy-bootstrap.yaml
fi

if [[ -f ${OPENSHIFT_INSTALL_DIR}/compute-nodes.yaml ]]; then
    cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/destroy-compute-nodes.yaml
- import_playbook: common.yaml

- hosts: all
  gather_facts: no

  tasks:

  - name: 'Delete Compute servers'
    os_server:
      name: "{{ item.1 }}-{{ item.0 }}"
      state: absent
      delete_fip: yes
    with_indexed_items: "{{ [os_compute_server_name] * os_compute_nodes_number }}"

EOF
    ansible-playbook -i $OPENSHIFT_INSTALL_DIR/inventory.yaml $OPENSHIFT_INSTALL_DIR/destroy-compute-nodes.yaml
fi

if [[ -f ${OPENSHIFT_INSTALL_DIR}/servers.yaml ]]; then
    cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/destroy-control-plane.yaml
- import_playbook: common.yaml

- hosts: all
  gather_facts: no

  tasks:
  - name: 'Delete the Control Plane servers'
    os_server:
      name: "{{ item.1 }}-{{ item.0 }}"
      state: absent
      delete_fip: yes
    with_indexed_items: "{{ [os_cp_server_name] * os_cp_nodes_number }}"

  - name: 'Delete the Control Plane ports'
    os_port:
      name: "{{ item.1 }}-{{ item.0 }}"
      state: absent
    with_indexed_items: "{{ [os_port_master] * os_cp_nodes_number }}"
  - name: 'Check if server group exists'
    command:
      cmd: "openstack server group show -f value -c name  {{ os_cp_server_group_name }}"
    register: server_group_for_delete
    ignore_errors: True
  - name: 'Delete the Control Plane server group'
    command:
      cmd: "openstack server group delete {{ os_cp_server_group_name }}"
    when: server_group_for_delete.stdout_lines | bool
EOF
    ansible-playbook -i $OPENSHIFT_INSTALL_DIR/inventory.yaml $OPENSHIFT_INSTALL_DIR/destroy-control-plane.yaml
fi


cat <<EOF > ${OPENSHIFT_INSTALL_DIR}/destroy_ports.yaml
- import_playbook: common.yaml
- hosts: all
  gather_facts: no
  tasks:
  - name: 'Remove helper-server'
    os_server:
      name: "{{ os_helper_server_name }}"
      state: absent
      delete_fip: yes
  - name: 'Remove the bootstrap server port'
    os_port:
      name: "{{ os_port_bootstrap }}"
      state: absent
  - name: 'Delete the Control Plane ports'
    os_port:
      name: "{{ item.1 }}-{{ item.0 }}"
      state: absent
    with_indexed_items: "{{ [os_port_master] * os_cp_nodes_number }}"
  - name: 'Delete Compute ports'
    os_port:
      name: "{{ item.1 }}-{{ item.0 }}"
      state: absent
    with_indexed_items: "{{ [os_port_worker] * os_compute_nodes_number }}"
  - name: 'Delete Helper port'
    os_port:
      name: "{{ os_port_helper }}"
      state: absent
  - name: 'Delete a subnet'
    os_subnet:
      name: "{{ os_subnet }}"
      state: absent
  - name: 'Delete a network'
    os_subnet:
      name: "{{ os_subnet }}"
      state: absent
EOF
ansible-playbook -i $OPENSHIFT_INSTALL_DIR/inventory.yaml $OPENSHIFT_INSTALL_DIR/destroy_ports.yaml

