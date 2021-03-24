# This can be used in 2 ways:
# 1) including as library (source common/collect_logs.sh; collect_docker_logs)
# 2) running as script (../common/collect_logs.sh collect_docker_logs)

# centos doesn't have this folder in PATH for ssh connections
export PATH=$PATH:/usr/sbin

function init_output_logging {
  if [[ -n "$TF_LOG_DIR" ]]; then
    mkdir -p $TF_LOG_DIR
    exec &> >(tee -a "${TF_LOG_DIR}/output.log")
    echo "INFO: =================== $(date) ==================="
  else
    echo "WARNING: TF_LOG_DIR is not set. output.log is not collected"
  fi
}

function create_log_dir() {
    if [[ -z "$TF_LOG_DIR" ]]; then
        echo "TF_LOG_DIR must be set"
        return 1
    fi

    mkdir -p $TF_LOG_DIR
}

function _docker_ps() {
    sudo docker ps -a --format '{{.ID}} {{.Names}}'
}

function _crictl_ps() {
    sudo crictl ps -a -o json | jq -r -c ".[][] | .id + \" \" + .metadata.name"
}

function collect_docker_logs() {
    local tool=${1:-docker}
    echo "INFO: Collecting docker logs"

    if ! which $tool &>/dev/null ; then
        echo "INFO: There is no any docker installed"
        return 0
    fi

    local log_dir="$TF_LOG_DIR/docker"
    mkdir -p $log_dir

    sudo $tool ps -a > $log_dir/__docker-ps.txt
    sudo $tool images > $log_dir/__docker-images.txt
    sudo $tool info > $log_dir/__docker-info.txt
    sudo $tool volume ls > $log_dir/__docker-volumes.txt
    local containers="$(_${tool}_ps)"
    local line
    local params
    while read -r line
    do
        read -r -a params <<< "$line"
        sudo $tool logs ${params[0]} &> $log_dir/${params[1]}.log
        sudo $tool inspect ${params[0]} &> $log_dir/${params[1]}.inspect
    done <<< "$containers"

    sudo chown -R $SUDO_UID:$SUDO_GID $TF_LOG_DIR/docker
}

function collect_contrail_status() {
    echo "INFO: Collecting contrail-status"
    mkdir -p $TF_LOG_DIR
    sudo contrail-status &> $TF_LOG_DIR/contrail-status
    sudo chown -R $SUDO_UID:$SUDO_GID $TF_LOG_DIR
}

function collect_kolla_logs() {
    echo "INFO: Collecting kolla logs"

    local log_dir="$TF_LOG_DIR/openstack"
    mkdir -p $log_dir

    if sudo ls /etc/kolla ; then
        sudo cp -R /etc/kolla $log_dir/
        sudo mv $log_dir/kolla $log_dir/kolla_etc
    fi

    local kl_path='/var/lib/docker/volumes/kolla_logs/_data'
    if sudo ls $kl_path ; then
        mkdir -p $log_dir/kolla_logs
        for ii in `sudo ls $kl_path/`; do
            sudo cp -R "$kl_path/$ii" $log_dir/kolla_logs/
        done
    fi

    sudo chown -R $SUDO_UID:$SUDO_GID $log_dir
    sudo find $log_dir -type f -exec chmod a+r {} \;
    sudo find $log_dir -type d -exec chmod a+rx {} \;
}

function collect_openstack_logs() {
    local hname=$1
    echo "INFO: Collecting openstack logs $hname"
    local log_dir="$TF_LOG_DIR"
    [ -z "$hname" ] ||  log_dir+="/$hname"
    log_dir+="/openstack"
    mkdir -p $log_dir
    local ldir
    for ldir in '/etc/nova' '/var/log/nova' '/var/lib/config-data/puppet-generated/nova' '/var/log/containers/nova' \
                '/var/lib/config-data/puppet-generated/nova_libvirt' '/var/log/containers/libvirt' \
                '/etc/haproxy' '/var/log/upstart' '/var/lib/config-data/puppet-generated/haproxy' '/var/log/containers/haproxy' \
                '/etc/neutron' '/var/log/neutron' '/var/lib/config-data/puppet-generated/neutron' '/var/log/containers/neutron' \
                '/etc/cinder' '/var/log/cinder' '/var/lib/config-data/puppet-generated/cinder' '/var/log/containers/cinder' \
                '/etc/keystone' '/var/log/keystone' '/var/lib/config-data/puppet-generated/keystone' '/var/log/containers/keystone' \
                '/etc/heat' '/var/log/heat' '/var/lib/config-data/puppet-generated/heat' '/var/log/containers/heat' \
                '/etc/glance' '/var/log/glance' '/var/lib/config-data/puppet-generated/glance' '/var/log/containers/glance' \
                '/etc/octavia' '/var/log/octavia' '/var/lib/config-data/puppet-generated/octavia' '/var/log/containers/octavia' \
                ; do
        if sudo ls "$ldir" >/dev/null 2>&1 ; then
            sudo cp -R -P $ldir $log_dir/
        fi
    done

    sudo chown -R $SUDO_UID:$SUDO_GID $log_dir
    sudo find $log_dir -type f -exec chmod a+r {} \;
    sudo find $log_dir -type d -exec chmod a+rx {} \;
}

function collect_contrail_logs() {
    echo "INFO: Collecting contrail logs"

    local log_dir="$TF_LOG_DIR/contrail"
    mkdir -p $log_dir

    if sudo ls /etc/contrail >/dev/null 2>&1 ; then
        echo "INFO: Collecting contrail logs: /etc/contrail"
        sudo cp -R /etc/contrail $log_dir/etc_contrail
    fi
    if sudo ls /etc/cni >/dev/null 2>&1 ; then
        echo "INFO: Collecting contrail logs: /etc/cni"
        sudo cp -R /etc/cni $log_dir/etc_cni
    fi

    local cl_path
    for cl_path in '/var/log/contrail' '/var/log/containers/contrail' ; do
        if sudo ls $cl_path >/dev/null 2>&1 ; then
            mkdir -p $log_dir/contrail_logs
            local ii
            for ii in `sudo ls $cl_path/`; do
                echo "INFO: Collecting contrail logs: $cl_path/$ii"
                sudo cp -R "$cl_path/$ii" $log_dir/contrail_logs/
            done
        fi
    done

    mkdir -p $log_dir/introspect
    local url=$(hostname -f)
    local ssl_opts=''
    local proto='http'
    if [[ "${SSL_ENABLE,,}" == 'true' ]] ; then
        proto='https'
        if  [[ -e /etc/contrail/ssl/private/server-privkey.pem ]] && \
            [[ -e /etc/contrail/ssl/certs/server.pem ]] && \
            [[ -e /etc/contrail/ssl/certs/ca-cert.pem || -e /etc/ipa/ca.crt ]] ; then

            ssl_opts="--key /etc/contrail/ssl/private/server-privkey.pem"
            ssl_opts+=" --cert /etc/contrail/ssl/certs/server.pem"
            if [[ -e /etc/contrail/ssl/certs/ca-cert.pem ]] ; then
                ssl_opts+=" --cacert /etc/contrail/ssl/certs/ca-cert.pem"
            else
                ssl_opts+=" --cacert /etc/ipa/ca.crt"
            fi
        else
            ssl_opts="-k"
        fi
    fi
    echo "INFO: Collecting contrail logs: save_introspect_info"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortConfigNodemgr 8100 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortControlNodemgr 8101 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortVRouterNodemgr 8102 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDatabaseNodemgr 8103 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAnalyticsNodemgr 8104 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortKubeManager 8108 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortConfigDatabaseNodemgr 8112 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAnalyticsAlarmNodemgr 8113 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAnalyticsSNMPNodemgr 8114 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDeviceManagerNodemgr 8115 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortControl 8083 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortApiServer 8084 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAgent 8085 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortSchemaTransformer 8087 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortSvcMonitor 8088 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDeviceManager 8096 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortCollector 8089 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortOpserver 8090 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortQueryEngine 8091 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDns 8092 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAlarmGenerator 5995 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortSnmpCollector 5920 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortTopology 5921 "$ssl_opts"

    sudo chown -R $SUDO_UID:$SUDO_GID $log_dir
    sudo find $log_dir -type f -exec chmod a+r {} \;
    sudo find $log_dir -type d -exec chmod a+rx {} \;
}

function save_introspect_info() {
    local hex_port=$(printf "%04X" "$4")
    if grep ":$hex_port" /proc/net/tcp* &>/dev/null; then
        echo "INFO: Collecting contrail logs: introspection request: curl -s $5 $2:$4/Snh_SandeshUVECacheReq?x=NodeStatus"
        sudo timeout -s 9 30 curl -s $5 $2:$4/Snh_SandeshUVECacheReq?x=NodeStatus >$1/$3.xml.log || true
    fi
}

function collect_system_stats() {
    local host_name=${1:-}
    echo "INFO: Collecting system statistics for logs"
    local syslogs="$TF_LOG_DIR"
    [ -z "$host_name" ] || syslogs+="/${host_name}"
    syslogs+="/system"
    mkdir -p "$syslogs"
    cat /proc/cmdline &> $syslogs/lx_cmdline.log
    ls /sys/devices/system/node/node*/hugepages/ &> $syslogs/hugepages.log
    echo "nr_hugepages" &>> $syslogs/hugepages.log
    cat /sys/devices/system/node/node*/hugepages/hugepages-*/nr_hugepages &>> $syslogs/hugepages.log
    echo "free_hugepages" &>> $syslogs/hugepages.log
    cat /sys/devices/system/node/node*/hugepages/hugepages-*/free_hugepages &>> $syslogs/hugepages.log
    ps ax -H &> $syslogs/ps.log
    sudo netstat -lpn &> $syslogs/netstat.log
    free -h &> $syslogs/mem.log
    df -h &> $syslogs/df.log
    ifconfig &>$syslogs/if.log
    ip addr &>$syslogs/ip_addr.log
    ip link &>$syslogs/ip_link.log
    ip route &>$syslogs/ip_route.log
    cat /proc/meminfo &>$syslogs/proc_meminfo
    cat /etc/hosts &>$syslogs/etc_hosts
    cat /etc/resolv.conf &>$syslogs/etc_resolv.conf
    ls -la /etc/ &>$syslogs/ls_etc.log
    if ps ax | grep -v grep | grep -q "bin/chronyd" ; then
        local chrony_cfg_file='/etc/chrony.conf'
        [ -e "$chrony_cfg_file" ] || chrony_cfg_file='/etc/chrony/chrony.conf'
        sudo cp $chrony_cfg_file $syslogs/  || true
        chronyc -n sources &>> $syslogs/chrony_sources.log || true
    elif ps ax | grep -v grep | grep -q "bin/ntpd" ; then
        sudo cp /etc/ntp.conf $syslogs/ || true
        /usr/sbin/ntpq -n -c pe &>> $syslogs/ntpq.log || true
    fi
    if [ -e /var/log/messages ] ; then
        yes | sudo cp /var/log/messages* $syslogs/
    fi
    if [ -e /var/log/syslog ] ; then
        yes | sudo cp /var/log/syslog* $syslogs/
    fi
    if which vif &>/dev/null ; then
        sudo vif --list &>$syslogs/vif.log
    fi
    if [ -d /etc/sysconfig ] ; then
        mkdir -p $syslogs/sysconfig
        sudo cp -r /etc/sysconfig/* $syslogs/sysconfig/ 2>/dev/null
    fi
    sudo dmesg &> $syslogs/dmesg.log
    sudo chown -R $SUDO_UID:$SUDO_GID $syslogs
    sudo find $syslogs -type f -exec chmod a+r {} \;
    sudo find $syslogs -type d -exec chmod a+rx {} \;
}

function collect_juju_status() {
    echo "INFO: Collected juju status"

    local log_dir="$TF_LOG_DIR/juju"
    mkdir -p "$log_dir"

    echo "INFO: Save juju statuses to logs"
    timeout -s 9 30 juju status --format yaml > $log_dir/juju_status.log
    timeout -s 9 30 juju status --format tabular > $log_dir/juju_status_tabular.log

    echo "INFO: Save current juju configuration to logs"
    command juju export-bundle > $log_dir/bundle.yaml

    echo "INFO: Save unit statuses to logs"
    for unit in `timeout -s 9 30 juju status $juju_model_arg --format oneline | awk '{print $2}' | sed 's/://g'` ; do
        if [[ -z "$unit" || "$unit" =~ "ubuntu/" || "$unit" =~ "ntp/" ]] ; then
            continue
        fi
      echo "INFO: --------------------------------- $unit statuses log" >> $log_dir/juju_unit_statuses.log
      command juju show-status-log $juju_model_arg --days 1 $unit >> $log_dir/juju_unit_statuses.log
    done
}

function collect_juju_logs() {
    echo "INFO: Collecting juju logs"
    mkdir -p $TF_LOG_DIR/juju
    sudo cp -r /var/log/juju/* $TF_LOG_DIR/juju/ 2>/dev/null
    sudo chown -R $SUDO_UID:$SUDO_GID $TF_LOG_DIR/juju/
    sudo find $TF_LOG_DIR/juju/ -type f -exec chmod a+r {} \;
}

function collect_kubernetes_logs() {
    local tool=${1:-kubectl}
    echo "INFO: Collecting kubernetes logs"
    if ! which $tool &>/dev/null ; then
        echo "INFO: There is no any kubernetes installed"
        return 0
    fi

    local KUBE_LOG_DIR=$TF_LOG_DIR/kubernetes_logs
    mkdir -p $KUBE_LOG_DIR

    local namespace=''
    local namespaces=`$tool get namespaces -o name | awk -F '/' '{ print $2 }'`
    for namespace in $namespaces ; do
        local pod=''
        local pods=`$tool get pods -n ${namespace} -o name | awk -F '/' '{ print $2 }'`
        for pod in $pods ; do
            local container
            local init_containers=$($tool get pod $pod -n ${namespace} -o json -o jsonpath='{.spec.initContainers[*].name}')
            local containers=$($tool get pod $pod -n ${namespace} -o json -o jsonpath='{.spec.containers[*].name}')
            for container in $init_containers $containers; do
                mkdir -p "$KUBE_LOG_DIR/pod-logs/${namespace}/${pod}"
                $tool logs ${pod} -n ${namespace} -c ${container} > "$KUBE_LOG_DIR/pod-logs/${namespace}/${pod}/${container}.txt"
            done
        done
    done
}

function _collect_kubernetes_object_info() {
    local tool=$1
    local log_dir=$2
    local resource=$3
    local namespace=$4
    local namespace_param=''
    if [[ -n "$namespace" ]]; then
        namespace_param="-n $namespace"
    fi
    echo "INFO: collect info for $resource"
    local object=''
    local objects_list=$($tool get ${namespace_param} ${resource} -o name)
    for object in $objects_list ; do
        echo "INFO: processing $object"
        mkdir -p "${log_dir}/${resource}"
        local name=${object#*/}
        local path_prefix="${log_dir}/${resource}/${namespace:+${namespace}_}${name}"
        $tool get ${namespace_param} ${resource} ${name} -o yaml 1> "${path_prefix}_get.txt" 2> /dev/null
        $tool describe ${namespace_param} ${resource} ${name} 1> "${path_prefix}_desc.txt" 2> /dev/null
    done
}

function collect_kubernetes_objects_info() {
    local tool=${1:-kubectl}
    echo "INFO: Collecting kubernetes object info"
    if ! which $tool &>/dev/null ; then
        echo "INFO: There is no any kubernetes installed"
        return 0
    fi

    local KUBE_OBJ_DIR=$TF_LOG_DIR/kubernetes_obj_info
    mkdir -p $KUBE_OBJ_DIR

    $tool get namespaces > $TF_LOG_DIR/kubernetes_namespaces
    $tool get nodes -o wide > $TF_LOG_DIR/kubernetes_nodes
    $tool get all --all-namespaces > $TF_LOG_DIR/kubernetes_all
    $tool api-resources > $TF_LOG_DIR/kubernetes_api-resources

    local resource
    local resources="pod daemonset.apps deployment.apps replicaset.apps statefulset.apps configmaps endpoints"
    resources+=" persistentvolumeclaims secrets serviceaccounts services jobs"
    local namespace=''
    local namespaces=$($tool get namespaces -o name | awk -F '/' '{ print $2 }')
    for namespace in $namespaces ; do
        echo "INFO: Processing namespace $namespace"
        for resource in $resources ; do
            _collect_kubernetes_object_info $tool $KUBE_OBJ_DIR $resource $namespace
        done
    done

    resources="persistentvolumes customresourcedefinitions storageclasses"
    for resource in $resources ; do
        _collect_kubernetes_object_info $tool $KUBE_OBJ_DIR $resource
    done

    echo "INFO: info collected"
}

function collect_core_dumps() {
    echo "INFO: Collecting core dumps"

    if ! command -v gdb &> /dev/null; then
        local distro=$(cat /etc/*release | egrep '^ID=' | awk -F= '{print $2}' | tr -d \")
        if [[ "$distro" == "centos" || "$distro" == "rhel" ]]; then
            sudo yum install -y gdb
        elif [ "$distro" == "ubuntu" ]; then
            export DEBIAN_FRONTEND=noninteractive
            sudo -E apt-get install -y gdb
        else
            echo "Unsupported OS version"
            return 1
        fi
    fi

    local DUMPS_DIR=$TF_LOG_DIR/core_dumps
    mkdir -p $DUMPS_DIR

    # gather core dumps
    cat <<COMMAND > /tmp/commands.txt
set height 0
t a a bt
quit
COMMAND
    local dump_path='/var/crashes'
    echo "INFO: cores: $(ls -l $dump_path/)"
    local core
    for core in $(ls -1 $dump_path/) ; do
        local x=$(basename "${core}")
        local y=$(echo $x | cut -d '.' -f 2)
        timeout -s 9 30 sudo gdb --command=/tmp/commands.txt -c $core $y > $DUMPS_DIR/$x-bt.log
    done
}

if [[ "${0}" == *"collect_logs.sh" ]] && [[ -n "${1}" ]]; then
    TF_LOG_DIR=${TF_LOG_DIR:-$(pwd)}
    $1
fi
# This can be used in 2 ways:
# 1) including as library (source common/collect_logs.sh; collect_docker_logs)
# 2) running as script (../common/collect_logs.sh collect_docker_logs)

# centos doesn't have this folder in PATH for ssh connections
export PATH=$PATH:/usr/sbin

function init_output_logging {
  if [[ -n "$TF_LOG_DIR" ]]; then
    mkdir -p $TF_LOG_DIR
    exec &> >(tee -a "${TF_LOG_DIR}/output.log")
    echo "INFO: =================== $(date) ==================="
  else
    echo "WARNING: TF_LOG_DIR is not set. output.log is not collected"
  fi
}

function create_log_dir() {
    if [[ -z "$TF_LOG_DIR" ]]; then
        echo "TF_LOG_DIR must be set"
        return 1
    fi

    mkdir -p $TF_LOG_DIR
}

function _docker_ps() {
    sudo docker ps -a --format '{{.ID}} {{.Names}}'
}

function _crictl_ps() {
    sudo crictl ps -a -o json | jq -r -c ".[][] | .id + \" \" + .metadata.name"
}

function collect_docker_logs() {
    local tool=${1:-docker}
    echo "INFO: Collecting docker logs"

    if ! which $tool &>/dev/null ; then
        echo "INFO: There is no any docker installed"
        return 0
    fi

    local log_dir="$TF_LOG_DIR/docker"
    mkdir -p $log_dir

    sudo $tool ps -a > $log_dir/__docker-ps.txt
    sudo $tool images > $log_dir/__docker-images.txt
    sudo $tool info > $log_dir/__docker-info.txt
    sudo $tool volume ls > $log_dir/__docker-volumes.txt
    local containers="$(_${tool}_ps)"
    local line
    local params
    while read -r line
    do
        read -r -a params <<< "$line"
        sudo $tool logs ${params[0]} &> $log_dir/${params[1]}.log
        sudo $tool inspect ${params[0]} &> $log_dir/${params[1]}.inspect
    done <<< "$containers"

    sudo chown -R $SUDO_UID:$SUDO_GID $TF_LOG_DIR/docker
}

function collect_tf_status() {
    echo "INFO: Collecting contrail-status"
    mkdir -p $TF_LOG_DIR
    sudo contrail-status &> $TF_LOG_DIR/contrail-status
    sudo chown -R $SUDO_UID:$SUDO_GID $TF_LOG_DIR
}

function collect_kolla_logs() {
    echo "INFO: Collecting kolla logs"

    local log_dir="$TF_LOG_DIR/openstack"
    mkdir -p $log_dir

    if sudo ls /etc/kolla ; then
        sudo cp -R /etc/kolla $log_dir/
        sudo mv $log_dir/kolla $log_dir/kolla_etc
    fi

    local kl_path='/var/lib/docker/volumes/kolla_logs/_data'
    if sudo ls $kl_path ; then
        mkdir -p $log_dir/kolla_logs
        for ii in `sudo ls $kl_path/`; do
            sudo cp -R "$kl_path/$ii" $log_dir/kolla_logs/
        done
    fi

    sudo chown -R $SUDO_UID:$SUDO_GID $log_dir
    sudo find $log_dir -type f -exec chmod a+r {} \;
    sudo find $log_dir -type d -exec chmod a+rx {} \;
}

function collect_openstack_logs() {
    local hname=$1
    echo "INFO: Collecting openstack logs $hname"
    local log_dir="$TF_LOG_DIR"
    [ -z "$hname" ] ||  log_dir+="/$hname"
    log_dir+="/openstack"
    mkdir -p $log_dir
    local ldir
    for ldir in '/etc/nova' '/var/log/nova' '/var/lib/config-data/puppet-generated/nova' '/var/log/containers/nova' \
                '/var/lib/config-data/puppet-generated/nova_libvirt' '/var/log/containers/libvirt' \
                '/etc/haproxy' '/var/log/upstart' '/var/lib/config-data/puppet-generated/haproxy' '/var/log/containers/haproxy' \
                '/etc/neutron' '/var/log/neutron' '/var/lib/config-data/puppet-generated/neutron' '/var/log/containers/neutron' \
                '/etc/cinder' '/var/log/cinder' '/var/lib/config-data/puppet-generated/cinder' '/var/log/containers/cinder' \
                '/etc/keystone' '/var/log/keystone' '/var/lib/config-data/puppet-generated/keystone' '/var/log/containers/keystone' \
                '/etc/heat' '/var/log/heat' '/var/lib/config-data/puppet-generated/heat' '/var/log/containers/heat' \
                '/etc/glance' '/var/log/glance' '/var/lib/config-data/puppet-generated/glance' '/var/log/containers/glance' \
                '/etc/octavia' '/var/log/octavia' '/var/lib/config-data/puppet-generated/octavia' '/var/log/containers/octavia' \
                ; do
        if sudo ls "$ldir" >/dev/null 2>&1 ; then
            sudo cp -R -P $ldir $log_dir/
        fi
    done

    sudo chown -R $SUDO_UID:$SUDO_GID $log_dir
    sudo find $log_dir -type f -exec chmod a+r {} \;
    sudo find $log_dir -type d -exec chmod a+rx {} \;
}

function collect_tf_logs() {
    echo "INFO: Collecting TF logs"

    local log_dir="$TF_LOG_DIR/tf"
    mkdir -p $log_dir

    if sudo ls /etc/contrail >/dev/null 2>&1 ; then
        echo "INFO: Collecting tf logs: /etc/contrail"
        sudo cp -R /etc/contrail $log_dir/etc_contrail
    fi
    if sudo ls /etc/cni >/dev/null 2>&1 ; then
        echo "INFO: Collecting tf logs: /etc/cni"
        sudo cp -R /etc/cni $log_dir/etc_cni
    fi

    local cl_path
    for cl_path in '/var/log/contrail' '/var/log/containers/contrail' ; do
        if sudo ls $cl_path >/dev/null 2>&1 ; then
            mkdir -p $log_dir/tf_logs
            local ii
            for ii in `sudo ls $cl_path/`; do
                echo "INFO: Collecting tf logs: $cl_path/$ii"
                sudo cp -R "$cl_path/$ii" $log_dir/tf_logs/
            done
        fi
    done

    mkdir -p $log_dir/introspect
    local url=$(hostname -f)
    local ssl_opts=''
    local proto='http'
    if [[ "${SSL_ENABLE,,}" == 'true' ]] ; then
        proto='https'
        if  [[ -e /etc/contrail/ssl/private/server-privkey.pem ]] && \
            [[ -e /etc/contrail/ssl/certs/server.pem ]] && \
            [[ -e /etc/contrail/ssl/certs/ca-cert.pem || -e /etc/ipa/ca.crt ]] ; then

            ssl_opts="--key /etc/contrail/ssl/private/server-privkey.pem"
            ssl_opts+=" --cert /etc/contrail/ssl/certs/server.pem"
            if [[ -e /etc/contrail/ssl/certs/ca-cert.pem ]] ; then
                ssl_opts+=" --cacert /etc/contrail/ssl/certs/ca-cert.pem"
            else
                ssl_opts+=" --cacert /etc/ipa/ca.crt"
            fi
        else
            ssl_opts="-k"
        fi
    fi
    echo "INFO: Collecting tf logs: save_introspect_info"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortConfigNodemgr 8100 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortControlNodemgr 8101 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortVRouterNodemgr 8102 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDatabaseNodemgr 8103 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAnalyticsNodemgr 8104 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortKubeManager 8108 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortConfigDatabaseNodemgr 8112 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAnalyticsAlarmNodemgr 8113 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAnalyticsSNMPNodemgr 8114 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDeviceManagerNodemgr 8115 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortControl 8083 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortApiServer 8084 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAgent 8085 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortSchemaTransformer 8087 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortSvcMonitor 8088 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDeviceManager 8096 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortCollector 8089 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortOpserver 8090 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortQueryEngine 8091 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortDns 8092 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortAlarmGenerator 5995 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortSnmpCollector 5920 "$ssl_opts"
    save_introspect_info $log_dir/introspect ${proto}://$url HttpPortTopology 5921 "$ssl_opts"

    sudo chown -R $SUDO_UID:$SUDO_GID $log_dir
    sudo find $log_dir -type f -exec chmod a+r {} \;
    sudo find $log_dir -type d -exec chmod a+rx {} \;
}

function save_introspect_info() {
    local hex_port=$(printf "%04X" "$4")
    if grep ":$hex_port" /proc/net/tcp* &>/dev/null; then
        echo "INFO: Collecting tf logs: introspection request: curl -s $5 $2:$4/Snh_SandeshUVECacheReq?x=NodeStatus"
        sudo timeout -s 9 30 curl -s $5 $2:$4/Snh_SandeshUVECacheReq?x=NodeStatus >$1/$3.xml.log || true
    fi
}

function collect_system_stats() {
    local host_name=${1:-}
    echo "INFO: Collecting system statistics for logs"
    local syslogs="$TF_LOG_DIR"
    [ -z "$host_name" ] || syslogs+="/${host_name}"
    syslogs+="/system"
    mkdir -p "$syslogs"
    cat /proc/cmdline &> $syslogs/lx_cmdline.log
    ls /sys/devices/system/node/node*/hugepages/ &> $syslogs/hugepages.log
    echo "nr_hugepages" &>> $syslogs/hugepages.log
    cat /sys/devices/system/node/node*/hugepages/hugepages-*/nr_hugepages &>> $syslogs/hugepages.log
    echo "free_hugepages" &>> $syslogs/hugepages.log
    cat /sys/devices/system/node/node*/hugepages/hugepages-*/free_hugepages &>> $syslogs/hugepages.log
    ps ax -H &> $syslogs/ps.log
    sudo netstat -lpn &> $syslogs/netstat.log
    free -h &> $syslogs/mem.log
    df -h &> $syslogs/df.log
    ifconfig &>$syslogs/if.log
    ip addr &>$syslogs/ip_addr.log
    ip link &>$syslogs/ip_link.log
    ip route &>$syslogs/ip_route.log
    cat /proc/meminfo &>$syslogs/proc_meminfo
    cat /etc/hosts &>$syslogs/etc_hosts
    cat /etc/resolv.conf &>$syslogs/etc_resolv.conf
    ls -la /etc/ &>$syslogs/ls_etc.log
    if ps ax | grep -v grep | grep -q "bin/chronyd" ; then
        local chrony_cfg_file='/etc/chrony.conf'
        [ -e "$chrony_cfg_file" ] || chrony_cfg_file='/etc/chrony/chrony.conf'
        sudo cp $chrony_cfg_file $syslogs/  || true
        chronyc -n sources &>> $syslogs/chrony_sources.log || true
    elif ps ax | grep -v grep | grep -q "bin/ntpd" ; then
        sudo cp /etc/ntp.conf $syslogs/ || true
        /usr/sbin/ntpq -n -c pe &>> $syslogs/ntpq.log || true
    fi
    if [ -e /var/log/messages ] ; then
        yes | sudo cp /var/log/messages* $syslogs/
    fi
    if [ -e /var/log/syslog ] ; then
        yes | sudo cp /var/log/syslog* $syslogs/
    fi
    if which vif &>/dev/null ; then
        sudo vif --list &>$syslogs/vif.log
    fi
    if [ -d /etc/sysconfig ] ; then
        mkdir -p $syslogs/sysconfig
        sudo cp -r /etc/sysconfig/* $syslogs/sysconfig/ 2>/dev/null
    fi
    sudo dmesg &> $syslogs/dmesg.log
    sudo chown -R $SUDO_UID:$SUDO_GID $syslogs
    sudo find $syslogs -type f -exec chmod a+r {} \;
    sudo find $syslogs -type d -exec chmod a+rx {} \;
}

function collect_juju_status() {
    echo "INFO: Collected juju status"

    local log_dir="$TF_LOG_DIR/juju"
    mkdir -p "$log_dir"

    echo "INFO: Save juju statuses to logs"
    timeout -s 9 30 juju status --format yaml > $log_dir/juju_status.log
    timeout -s 9 30 juju status --format tabular > $log_dir/juju_status_tabular.log

    echo "INFO: Save current juju configuration to logs"
    command juju export-bundle > $log_dir/bundle.yaml

    echo "INFO: Save unit statuses to logs"
    for unit in `timeout -s 9 30 juju status $juju_model_arg --format oneline | awk '{print $2}' | sed 's/://g'` ; do
        if [[ -z "$unit" || "$unit" =~ "ubuntu/" || "$unit" =~ "ntp/" ]] ; then
            continue
        fi
      echo "INFO: --------------------------------- $unit statuses log" >> $log_dir/juju_unit_statuses.log
      command juju show-status-log $juju_model_arg --days 1 $unit >> $log_dir/juju_unit_statuses.log
    done
}

function collect_juju_logs() {
    echo "INFO: Collecting juju logs"
    mkdir -p $TF_LOG_DIR/juju
    sudo cp -r /var/log/juju/* $TF_LOG_DIR/juju/ 2>/dev/null
    sudo chown -R $SUDO_UID:$SUDO_GID $TF_LOG_DIR/juju/
    sudo find $TF_LOG_DIR/juju/ -type f -exec chmod a+r {} \;
}

function collect_kubernetes_logs() {
    local tool=${1:-kubectl}
    echo "INFO: Collecting kubernetes logs"
    if ! which $tool &>/dev/null ; then
        echo "INFO: There is no any kubernetes installed"
        return 0
    fi

    local KUBE_LOG_DIR=$TF_LOG_DIR/kubernetes_logs
    mkdir -p $KUBE_LOG_DIR

    local namespace=''
    local namespaces=`$tool get namespaces -o name | awk -F '/' '{ print $2 }'`
    for namespace in $namespaces ; do
        local pod=''
        local pods=`$tool get pods -n ${namespace} -o name | awk -F '/' '{ print $2 }'`
        for pod in $pods ; do
            local container
            local init_containers=$($tool get pod $pod -n ${namespace} -o json -o jsonpath='{.spec.initContainers[*].name}')
            local containers=$($tool get pod $pod -n ${namespace} -o json -o jsonpath='{.spec.containers[*].name}')
            for container in $init_containers $containers; do
                mkdir -p "$KUBE_LOG_DIR/pod-logs/${namespace}/${pod}"
                $tool logs ${pod} -n ${namespace} -c ${container} > "$KUBE_LOG_DIR/pod-logs/${namespace}/${pod}/${container}.txt"
            done
        done
    done
}

function _collect_kubernetes_object_info() {
    local tool=$1
    local log_dir=$2
    local resource=$3
    local namespace=$4
    local namespace_param=''
    if [[ -n "$namespace" ]]; then
        namespace_param="-n $namespace"
    fi
    echo "INFO: collect info for $resource"
    local object=''
    local objects_list=$($tool get ${namespace_param} ${resource} -o name)
    for object in $objects_list ; do
        echo "INFO: processing $object"
        mkdir -p "${log_dir}/${resource}"
        local name=${object#*/}
        local path_prefix="${log_dir}/${resource}/${namespace:+${namespace}_}${name}"
        $tool get ${namespace_param} ${resource} ${name} -o yaml 1> "${path_prefix}_get.txt" 2> /dev/null
        $tool describe ${namespace_param} ${resource} ${name} 1> "${path_prefix}_desc.txt" 2> /dev/null
    done
}

function collect_kubernetes_objects_info() {
    local tool=${1:-kubectl}
    echo "INFO: Collecting kubernetes object info"
    if ! which $tool &>/dev/null ; then
        echo "INFO: There is no any kubernetes installed"
        return 0
    fi

    local KUBE_OBJ_DIR=$TF_LOG_DIR/kubernetes_obj_info
    mkdir -p $KUBE_OBJ_DIR

    $tool get namespaces > $TF_LOG_DIR/kubernetes_namespaces
    $tool get nodes -o wide > $TF_LOG_DIR/kubernetes_nodes
    $tool get all --all-namespaces > $TF_LOG_DIR/kubernetes_all
    $tool api-resources > $TF_LOG_DIR/kubernetes_api-resources

    local resource
    local resources="pod daemonset.apps deployment.apps replicaset.apps statefulset.apps configmaps endpoints"
    resources+=" persistentvolumeclaims secrets serviceaccounts services jobs"
    local namespace=''
    local namespaces=$($tool get namespaces -o name | awk -F '/' '{ print $2 }')
    for namespace in $namespaces ; do
        echo "INFO: Processing namespace $namespace"
        for resource in $resources ; do
            _collect_kubernetes_object_info $tool $KUBE_OBJ_DIR $resource $namespace
        done
    done

    resources="persistentvolumes customresourcedefinitions storageclasses"
    for resource in $resources ; do
        _collect_kubernetes_object_info $tool $KUBE_OBJ_DIR $resource
    done

    echo "INFO: info collected"
}

function run_command_on_pod() {
    local command=$1
    local pod=$2
    local container=${3:-""}
    local namespace=${4:-"contrail"}
    local tool=${5:-"kubectl"}

    $tool -n "$namespace" exec -c "$container" "$pod" -- bash -c "$command" 2>/dev/null
}

function get_service_pod_namespaced_names() {
    local service=$1
    local tool=${2:-"kubectl"}

    local pods="$($tool get pods --field-selector=status.phase=Running --all-namespaces | grep "$service")"

    echo "$pods" | awk '{print $1 " " $2 }'
}

function collect_cmd_from_service_pods() {
    local service=$1
    local log_file=$2
    local command=$3
    local container=${4:-""}
    local tool=${5:-"kubectl"}

    get_service_pod_namespaced_names "$service" "$tool" | while read -r namespace pod; do
        printf "%s at %s:\n\n" "$pod" "$(date)" >> $log_file
        run_command_on_pod "$command" "$pod" "$container" "$namespace" "$tool" >> $log_file
        printf "\n\n" >> $log_file
    done
}

function collect_kubernetes_service_statuses() {
    local tool=${1:-"kubectl"}

    echo "INFO: Collecting statuses from cassandra, zookeeper and rabbitmq services"

    if ! which $tool &>/dev/null ; then
        echo "INFO: There is no any $tool installed"
        return 0
    fi

    # Cassandra
    local command="echo \"Port 7200:\"; nodetool -p 7200 status; echo \"Port 7201:\"; nodetool -p 7201 status"
    collect_cmd_from_service_pods "cassandra\|configdb" "$TF_LOG_DIR/cassandra_status.log" "$command" "" "$tool"

    # Zookeeper
    local log_file="$TF_LOG_DIR/zookeeper_status.log"
    get_service_pod_namespaced_names "zookeeper" "$tool" | while read -r namespace pod; do
        local pod_ip=$($tool get pod "$pod" -n "$namespace" --template={{.status.podIP}})
        command="zkCli.sh -server $pod_ip config; echo $pod_ip"

        printf "%s at %s:\n\n" "$pod" "$(date)" >> $log_file
        run_command_on_pod "$command" "$pod" "" "$namespace" "$tool" >> $log_file
        printf "\n\n" >> $log_file
    done

    #Rabbitmq
    command="source /etc/rabbitmq/rabbitmq-common.env; rabbitmqctl cluster_status"
    collect_cmd_from_service_pods "rabbitmq" "$TF_LOG_DIR/rabbitmq_status.log" "$command" "" "$tool"

    command="source /etc/rabbitmq/rabbitmq-common.env;
             vhosts=\$(rabbitmqctl list_vhosts | tail -n +3);
             rabbitmqctl list_policies -p \$vhosts"
    collect_cmd_from_service_pods "rabbitmq" "$TF_LOG_DIR/rabbitmq_policies.log" "$command" "" "$tool"
}

function collect_core_dumps() {
    echo "INFO: Collecting core dumps"

    if ! command -v gdb &> /dev/null; then
        local distro=$(cat /etc/*release | egrep '^ID=' | awk -F= '{print $2}' | tr -d \")
        if [[ "$distro" == "centos" || "$distro" == "rhel" ]]; then
            sudo yum install -y gdb
        elif [ "$distro" == "ubuntu" ]; then
            export DEBIAN_FRONTEND=noninteractive
            sudo -E apt-get install -y gdb
        else
            echo "Unsupported OS version"
            return 1
        fi
    fi

    local DUMPS_DIR=$TF_LOG_DIR/core_dumps
    mkdir -p $DUMPS_DIR

    # gather core dumps
    cat <<COMMAND > /tmp/commands.txt
set height 0
t a a bt
quit
COMMAND
    local dump_path='/var/crashes'
    echo "INFO: cores: $(ls -l $dump_path/)"
    local core
    for core in $(ls -1 $dump_path/) ; do
        local x=$(basename "${core}")
        local y=$(echo $x | cut -d '.' -f 2)
        timeout -s 9 30 sudo gdb --command=/tmp/commands.txt -c $core $y > $DUMPS_DIR/$x-bt.log
    done
}

if [[ "${0}" == *"collect_logs.sh" ]] && [[ -n "${1}" ]]; then
    TF_LOG_DIR=${TF_LOG_DIR:-$(pwd)}
    $1
fi