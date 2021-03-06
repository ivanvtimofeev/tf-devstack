#!/bin/bash

function process_manifest() {
    local folder=$1
    local templates_to_render=`ls $folder/*.j2`
    local template
    for template in $templates_to_render ; do
        local rendered_yaml=$(echo "${template%.*}")
        "$my_dir/../common/jinja2_render.py" < $template > $rendered_yaml
    done
}

function collect_logs_from_machines() {

    collect_kubernetes_objects_info ./oc
    collect_kubernetes_logs ./oc

    cat <<EOF >/tmp/logs.sh
#!/bin/bash
tgz_name=\$1
export WORKSPACE=/tmp/openshift-logs
export TF_LOG_DIR=/tmp/openshift-logs/logs
export SSL_ENABLE=$SSL_ENABLE
cd /tmp/openshift-logs
source ./collect_logs.sh
collect_system_stats
collect_contrail_status
collect_docker_logs crictl
collect_contrail_logs
sudo chmod -R a+r logs
pushd logs
tar -czf \$tgz_name *
popd
cp logs/\$tgz_name \$tgz_name
sudo rm -rf logs
EOF
    chmod a+x /tmp/logs.sh

    export CONTROLLER_NODES="` | tr '\n' ','`"
    echo "INFO: controller_nodes: $CONTROLLER_NODES"
    export AGENT_NODES="`./oc get nodes -o wide | awk '/ worker /{print $6}' | tr '\n' ','`"

    local machine
    for machine in $(./oc get nodes -o wide --no-headers | awk '{print $6}' | sort -u) ; do
        local ssh_dest="core@$machine"
        local tgz_name="logs-$machine.tgz"
        mkdir -p $TF_LOG_DIR/$machine
        ssh $SSH_OPTS $ssh_dest "mkdir -p /tmp/openshift-logs"
        scp $SSH_OPTS $my_dir/../common/collect_logs.sh $ssh_dest:/tmp/openshift-logs/collect_logs.sh
        scp $SSH_OPTS /tmp/logs.sh $ssh_dest:/tmp/openshift-logs/logs.sh
        ssh $SSH_OPTS $ssh_dest /tmp/openshift-logs/logs.sh $tgz_name
        scp $SSH_OPTS $ssh_dest:/tmp/openshift-logs/$tgz_name $TF_LOG_DIR/$machine/
        pushd $TF_LOG_DIR/$machine/
        tar -xzf $tgz_name
        rm -rf $tgz_name
        popd
    done
}
