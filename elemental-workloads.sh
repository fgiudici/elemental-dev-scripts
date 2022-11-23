#!/bin/bash

EO_NS=fleet-default
EO_CRDS="managedosimages.elemental.cattle.io \
         machineinventories.elemental.cattle.io \
         machineregistrations.elemental.cattle.io \
         managedosversions.elemental.cattle.io \
         managedosversionchannels.elemental.cattle.io \
         machineinventoryselectors.elemental.cattle.io \
         machineinventoryselectortemplates.elemental.cattle.io \
         managedosimages.elemental.cattle.io"

REG_NAME=elem1

get_resource_list() {
    local res="$1"

    kubectl get -n $EO_NS $res -o custom-columns=":metadata.name"
}

machine_registration() {
    cat << "EOF"
apiVersion: elemental.cattle.io/v1beta1
kind: MachineRegistration
metadata:
  name: elem1
  namespace: fleet-default
spec:
  config:
    elemental:
      install:
        device: /dev/vda
        reboot: true
        debug: true
    cloud-config:
      users:
        - name: root
          passwd: password
  machineInventoryLabels:
    cluster-id: "elemental-k3s"
EOF
}

machine_registration_no_tpm() {
    cat << "EOF"
apiVersion: elemental.cattle.io/v1beta1
kind: MachineRegistration
metadata:
  name: elem1
  namespace: fleet-default
spec:
  config:
    elemental:
      registration:
        emulate-tpm: true
      install:
        device: /dev/vda
        reboot: false
        debug: true
    cloud-config:
      users:
        - name: root
          passwd: password
  machineInventoryLabels:
    cluster-id: "elemental-k3s"
EOF
}

cluster() {
    cat << "EOF"
apiVersion: elemental.cattle.io/v1beta1
kind: MachineInventorySelectorTemplate
metadata:
  name: elemental-k3s
  namespace: fleet-default
spec:
  template:
    spec:
      selector:
        matchExpressions:
        - key: cluster-id
          operator: In
          values: [ 'elemental-k3s' ]
---
kind: Cluster
apiVersion: provisioning.cattle.io/v1
metadata:
  name: elemental-k3s
  namespace: fleet-default
spec:
  rkeConfig:
    machinePools:
    - controlPlaneRole: true
      etcdRole: true
      workerRole: true
      machineConfigRef:
        apiVersion: elemental.cattle.io/v1beta1
        kind: MachineInventorySelectorTemplate
        name: elemental-k3s
      name: pool-elemental
      quantity: 1
      unhealthyNodeTimeout: 0s
  kubernetesVersion: v1.25.2+k3s1
EOF
}

if [ "$1" = "delete" ]; then
    for res in machineinventories.elemental.cattle.io machineregistrations.elemental.cattle.io machineinventoryselectortemplates.elemental.cattle.io cluster; do
        echo "- Delete $res"
        for i in `get_resource_list "$res"`; do
            echo "  . delete $i"
            kubectl delete -n $EO_NS $res $i
        done
    done
elif [ "$1" = "check" ]; then
    for i in $EO_CRDS; do
        echo "-- $i--"
        kubectl get $i --all-namespaces
        echo "---------------------"
    done
elif [ "$1" = "machine" ]; then
    if [ "$2" = "no-tpm" ]; then
        machine_registration_no-tpm | kubectl create -f -
    else
        machine_registration | kubectl create -f -
    fi
    sleep 1
    REGISTRATION_URL=`kubectl get machineregistration -n fleet-default elem1 -ojsonpath="{.status.registrationURL}"`
    curl -k $REGISTRATION_URL | tee reg.yaml
elif [ "$1" = "cluster" ]; then
    cluster | kubectl create  -f -
elif [ "$1" = "create" ]; then
    cluster | cat > Cluster.yaml
    machine_registration | cat > MachineRegistration.yaml
else
    echo "Usage: $0 [delete|check|create|machine <no-tpm>|cluster]"
    exit 0
fi

