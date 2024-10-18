#!/bin/sh

VERSION="0.3.0"

# you can set your custom vars permanently in $HOME/.elemental/config
: ${ENVC:="$HOME/.elemental/config"}
if [ "$ENVC" != "skip" -a -f "$ENVC" ]; then
  . "$ENVC"
fi


: ${CFG_HOSTNAME:="ubuntu"}
: ${VM_STORE:="/var/lib/libvirt/images"}
: ${VM_DISKSIZE:="30"}
: ${VM_MEMORY:="4096"}
: ${VM_NETWORK:="default"}
: ${VM_CORES:="2"}
: ${VM_GRAPHICS:="spice"}

#DISTRO_NAME="ubuntu22.04"
DISTRO_NAME="ubuntu20.04"
QEMU_IMG="${DISTRO_NAME}.qcow2"
VM_DISKSIZE="${VM_DISKSIZE}G"
LOOPDEV=""

error() {
  msg="${1}"
  echo ERR: ${msg:-"command failed"}

  exit -1
}

create_vm() {
  local uuid=$(uuidgen) || error
  local vmdisk="${uuid}-${DISTRO_NAME}.qcow2"

  [ -f "$VM_STORE/$QEMU_IMG" ] || error "$VM_STORE/$QEMU_IMG not found"

  sudo cp -a "${VM_STORE}/${QEMU_IMG}" "${VM_STORE}/${vmdisk}" || error

  sudo virt-sysprep --hostname ${CFG_HOSTNAME} --enable dhcp-client-state,machine-id,customize \
    -a "${VM_STORE}/${vmdisk}"

  sudo virt-install \
    -n "${DISTRO_NAME}-$uuid" --osinfo="${DISTRO_NAME}" --memory="$VM_MEMORY" --vcpus="$VM_CORES" \
    --disk path="${VM_STORE}/${vmdisk}",bus=virtio --import \
    --graphics "$VM_GRAPHICS" \
    --network network="$VM_NETWORK" \
    --boot uefi \
    --noautoconsole
}

help() {
  cat << EOF
Usage:
  ${0//*\/} CMD

  list of commands (CMD):
    create                # creates a VM backed up by the disks created by "artifacts", with VM_MEMORY memory and VM_CORES vcpus.
                          # if the artifacts folder is not found, calls "artifacts" first to generate the required disks
  supported env vars:
    ENVC                # the environment config file to be imported if present (default: '\$HOME/.elemental/config)
                        # set to 'skip' to skip importing env variable declarations from any file
    VM_CORES            # number of vcpus assigned to the leapmicro K3s VM (default: '2')
    VM_GRAPHICS         # graphical display configuration for the leapmicro K3s VM (default: 'spice')
    VM_MEMORY           # amount of RAM assigned to the leapmicro K3s VM in MiB (default: '4096')
    VM_NETWORK          # virtual network (default: 'default')
    VM_STORE            # path where to put the disks for the leapmicro K3s VM (default: '$VM_STORE')
    CFG_HOSTNAME        # provisioned hostname (default: '$CFG_HOSTNAME')

example:
  VM_STORAGE=/data/images/ VM_NETWORK="net-name,mac=52:54:00:00:01:fe" VM_MEMORY=8192 VM_CORES=4 ./ubuntu.sh create

EOF

  exit 0
}

case ${1} in

  create)
    sudo echo ""

    create_vm
    ;;

  *)
    help
    ;;

esac
