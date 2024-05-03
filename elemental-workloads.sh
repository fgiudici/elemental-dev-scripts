#!/bin/bash

VERSION="0.3.0"

EO_NS=fleet-default
EO_CRDS="managedosimages.elemental.cattle.io \
         machineinventories.elemental.cattle.io \
         machineregistrations.elemental.cattle.io \
         seedimages.elemental.cattle.io \
         managedosversions.elemental.cattle.io \
         managedosversionchannels.elemental.cattle.io \
         machineinventoryselectors.elemental.cattle.io \
         machineinventoryselectortemplates.elemental.cattle.io \
         managedosimages.elemental.cattle.io"

EO_CRDS_DEL="managedosimages.elemental.cattle.io \
             machineinventories.elemental.cattle.io \
             machineregistrations.elemental.cattle.io \
             seedimages.elemental.cattle.io \
             machineinventoryselectors.elemental.cattle.io \
             machineinventoryselectortemplates.elemental.cattle.io \
             managedosimages.elemental.cattle.io"

case ${2} in

  --*)
    if [ "$2" != "--notpm" ]; then help; fi
    NOTPM="true"
    if [ -n "${3}" ]; then BASE_NAME=${3}; fi
    ;;

  *)
    if [ -n "${2}" ]; then BASE_NAME=${2}; fi
  ;;

esac

: ${DEFAULT_CLUSTER:="v1.27.11+k3s1"}
: ${DEFAULT_MACHINE_DISK:="/dev/vda"}
: ${DEFAULT_ROOT_PWD:="elemental"}

: ${BASE_NAME:="test"}
: ${CLUSTER_NAME:=$BASE_NAME}
: ${LABEL_KEY:="cluster-id"}
: ${LABEL_VAL:="${BASE_NAME}"}
: ${N_NODES:=1}

: ${BASE_ISO:="Stable"}

case $BASE_ISO in
  stable|Stable)
    BASE_ISO=registry.suse.com/suse/sle-micro-iso/5.5:latest
    ;;
esac

get_resource_list() {
    local res="$1"

    kubectl get -n $EO_NS $res -o custom-columns=":metadata.name"
}

machine_registration() {
  cat << EOF
apiVersion: elemental.cattle.io/v1beta1
kind: MachineRegistration
metadata:
  name: $BASE_NAME
  namespace: fleet-default
spec:
  config:
    elemental:
      install:
        device: $DEFAULT_MACHINE_DISK
        reboot: true
        debug: true
EOF

  if [ "$NOTPM" = true ]; then
    cat << EOF
      registration:
        emulate-tpm: true
        emulated-tpm-seed: -1
EOF

  elif [ "$REGAUTH" != "" ]; then
    cat << EOF
      registration:
        auth: $REGAUTH
EOF

  fi

  cat << EOF
    cloud-config:
      users:
        - name: root
          passwd: $DEFAULT_ROOT_PWD
        - name: elemental
          passwd: elemental
  machineInventoryLabels:
    $LABEL_KEY: $LABEL_VAL
    manufacturer: "\${System Information/Manufacturer}"
    productName: "\${System Information/Product Name}"
    serialNumber: "\${System Information/Serial Number}"
    machineUUID: "\${System Information/UUID}"
EOF
}

cluster() {
  cat << EOF
apiVersion: elemental.cattle.io/v1beta1
kind: MachineInventorySelectorTemplate
metadata:
  name: $CLUSTER_NAME
  namespace: fleet-default
spec:
  template:
    spec:
      selector:
        matchExpressions:
        - key: $LABEL_KEY
          operator: In
          values: [ '$LABEL_VAL' ]
---
kind: Cluster
apiVersion: provisioning.cattle.io/v1
metadata:
  name: $CLUSTER_NAME
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
        name: $CLUSTER_NAME
      name: ${CLUSTER_NAME}-pool
      quantity: $N_NODES
      unhealthyNodeTimeout: 0s
  kubernetesVersion: $DEFAULT_CLUSTER
EOF
}

seed_image() {
  cat << EOF
apiVersion: elemental.cattle.io/v1beta1
kind: SeedImage
metadata:
  name: $BASE_NAME
  namespace: fleet-default
spec:
  baseImage: $BASE_ISO
  cleanupAfterMinutes: 60
  registrationRef:
    name: $BASE_NAME
    namespace: fleet-default
  type: iso
EOF
}


help() {
  cat << EOF
Usage:
  ${0//*\/} CMD [--notpm] [BASE-NAME]

  list of commands (CMD):
    check           # prints all the elemental workload resources under all namespaces
    delete          # deletes all the elemental workload resources under the $EO_NS namespace
    create  [notpm] # creates yaml files containing the resources required to deploy an elemental cluster
    machine [notpm] # creates a MachineRegistration resource in the kubernetes cluster (kubectl should be configured)
    cluster         # creates Cluster and MachineInventoryTemplate resources in the kubernetes cluster (kubectl should be configured)
    seedimg         # creates a SeedImage resources in the kubernetes cluster (kubectl should be configured)
    getreg          # writes the elemental registration yaml in the current dir
  list of options:
    --notpm         # generates a MachineRegistration with parameters to emulate TPM (NOTPM=true env var will be the same)
  list of optional args:
    BASE-NAME   # the base name is used to generate resources: it will be the name of the MachineRegistration and will be used to derive
                # the names of other resources and of generated files. It is optional, by default it is set to "test".
  supported env vars:
    DEFAULT_CLUSTER       # cluster to be provisioned (default: "v1.25.6+k3s1")
    DEFAULT_MACHINE_DISK  # node disk device on which elemental will be installed (default: "/dev/vda")
    DEFAULT_ROOT_PWD      # root password of the deployed elemental nodes (default: "password"}
    BASE_NAME             # can be use to set the BASE-NAME and avoid passing it on the command line (see BASE-NAME, default: "test")
    CLUSTER_NAME          # name of the generated Cluster and SelectorTemplate (default: equal to BASE_NAME)
    LABEL_KEY             # label key added to the provisioned hosts, used to match the host to the cluster (default: "cluster-id")
    LABEL_VAL             # label val added to the provisioned hosts, used to match the host to the cluster (default: equal to BASE_NAME)
    N_NODES               # desider number of nodes that will be part of the cluster (default: 1)
    NOTPM=true            # generates a MachineRegistration with emulated tpm
    REGAUTH               # alternative authentication to use (instead of tpm); possible values: "mac", "sys-uuid"
    BASE_ISO              # the URL of the base iso for the generated SeedImage (or Stable/Staging/Dev for OBS ones, default: Dev)
  example:
    $> CLUSTER_NAME=volcano LABEL_KEY=element elemental-workloads.sh create fire
EOF

  exit 0
}



case ${1} in

  check)
    echo "CLUSTERS:"
    kubectl get clusters.provisioning.cattle.io --all-namespaces
    echo ""
    for i in $EO_CRDS; do
        echo "[ $i ]"
        kubectl get $i --all-namespaces
        echo "----------------------------------------"
        echo ""
    done
    ;;

  create)
    machine_registration | cat > MachineRegistration-${BASE_NAME}.yaml
    cluster | cat > Cluster-${BASE_NAME}.yaml
    seed_image | cat > SeedImage-${BASE_NAME}.yaml
    ;;

  delete)
    for res in $EO_CRDS_DEL cluster; do
        echo "- Delete $res"
        for i in `get_resource_list "$res"`; do
            echo "  . delete $i"
            kubectl delete -n $EO_NS $res $i
        done
    done
    ;;

  machine)
    machine_registration | kubectl create -f -
    sleep 1
    REGISTRATION_URL=`kubectl get machineregistration -n fleet-default ${BASE_NAME} -ojsonpath="{.status.registrationURL}"`
    curl -k $REGISTRATION_URL | tee reg-${BASE_NAME}.yaml
    ;;

  cluster)
    cluster | kubectl create  -f -
    ;;

  seedimg)
    seed_image | lubectl create -f -
    ;;

  getreg)
    REGISTRATION_URL=`kubectl get machineregistration -n fleet-default ${BASE_NAME} -ojsonpath="{.status.registrationURL}"`
    curl -k $REGISTRATION_URL | tee reg-${BASE_NAME}.yaml
    ;;

  *)
    help
    ;;

esac

