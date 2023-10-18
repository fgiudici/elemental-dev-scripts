#!/bin/sh

VERSION="0.2.0"
OUTPUT_DIR="artifacts"
CONF_IMG="ignition.img"
DOWNLOAD_QCOW=false

# you can set your custom vars permanently in $HOME/.elemental/config
: ${ENVC:="$HOME/.elemental/config"}
if [ "$ENVC" != "skip" -a -f "$ENVC" ]; then
  . "$ENVC"
fi


: ${MICRO_OS:=leapmicro}
: ${SKIP_K3S:=false}
: ${CFG_ROOT_PWD:="elemental"}
: ${CFG_SSH_KEY:=""}
: ${CFG_HOSTNAME:="$MICRO_OS"}
: ${VM_STORE:="/var/lib/libvirt/images"}
: ${VM_DISKSIZE:="30"}
: ${VM_MEMORY:="4096"}
: ${VM_NETWORK:="default"}
: ${VM_CORES:="2"}
: ${VM_GRAPHICS:="spice"}
: ${VM_AUTOCONSOLE:="text"}
: ${INSTALL_K3S_EXEC:="server --write-kubeconfig-mode=644"}
: ${INSTALL_K3S_VERSION:="v1.25.10+k3s1"}
: ${RANCHER_PWD:="rancher4elemental"}
: ${RANCHER_VER:=""}
: ${REMOTE_KVM:=""}

case "$MICRO_OS" in
  leapmicro)
    DISTRO_NAME="openSUSE-Leap-Micro.x86_64-Default"
    DISTRO_URL_BASE="https://download.opensuse.org/distribution/leap-micro/5.4/appliances/"
    ;;
  microOS|microos)
    DISTRO_NAME="openSUSE-MicroOS.x86_64-ContainerHost-kvm-and-xen"
    DISTRO_URL_BASE="https://download.opensuse.org/tumbleweed/appliances/"
    DOWNLOAD_QCOW=true
    ;;
  *)
    echo ERR: parameter \"$MICRO_OS\" is not a valid OS
    exit -1
    ;;
esac

VM_DISKSIZE="${VM_DISKSIZE}G"
DISTRO_RAW="${DISTRO_NAME}.raw"
DISTRO_RAWXZ="${DISTRO_RAW}.xz"
QEMU_IMG="${DISTRO_NAME}.qcow2"
DISTRO_FULL_URL="${DISTRO_URL_BASE}${DISTRO_RAWXZ}"
LOOPDEV=""

error() {
  msg="${1}"
  echo ERR: ${msg:-"command failed"}

  ignition_volume_prep_cleanup
  exit -1
}

write_ignition() {
  ROOT_HASHED_PWD=$(openssl passwd -6 "$CFG_ROOT_PWD") || error

  cat << EOF
variant: fcos
version: 1.3.0

passwd:
    users:
      - name: root
        password_hash: "$ROOT_HASHED_PWD"
storage:
  files:
    - path: /etc/hostname
      contents:
        inline: "$CFG_HOSTNAME"
      mode: 0644
      overwrite: true
EOF

  if [ -n "$CFG_SSH_KEY" ]; then
    cat << EOF
    - path: /root/.ssh/authorized_keys
      contents:
        inline: "$CFG_SSH_KEY"
      mode: 0600
      overwrite: true
EOF
  fi
}

write_combustion() {
  if $SKIP_K3S; then
    echo ""
    return
  fi

  cat << EOF
#!/bin/sh
# combustion: network

curl -L --output k3s_installer.sh https://get.k3s.io && install -m755 k3s_installer.sh /usr/bin/

cat <<- END > /etc/systemd/system/install-rancher-k3s.service
[Unit]
Description=Run K3s installer
Wants=network-online.target
After=network.target network-online.target
ConditionPathExists=/usr/bin/k3s_installer.sh
ConditionPathExists=!/usr/local/bin/k3s
OnSuccess=reboot.target
[Service]
Type=forking
TimeoutStartSec=120
Environment="INSTALL_K3S_EXEC=$INSTALL_K3S_EXEC"
Environment="INSTALL_K3S_VERSION=$INSTALL_K3S_VERSION"
ExecStart=/usr/bin/k3s_installer.sh
RemainAfterExit=no
KillMode=process
[Install]
WantedBy=multi-user.target
END

systemctl enable sshd
systemctl enable install-rancher-k3s.service

echo "Configured with Combustion" > /etc/issue.d/combustion
EOF
}

create_config_files() {
  write_ignition > config.fcc
  write_combustion > script
}

ignition_volume_prep() {
  local lodevs

  echo "* build ignition/combustion config image volume"
  # 1000Kb disk img
  dd if=/dev/zero of="$CONF_IMG" count=2000 || error

  sudo losetup -f "$CONF_IMG" || error
  lodevs=$(sudo losetup -j "$CONF_IMG") || error

  LOOPDEV=$(echo $lodevs | cut -d ":" -f 1 | head -n 1)
  [ -z "$LOOPDEV" ] && error "cannot find loop device"

  sudo mkfs.ext4 $LOOPDEV
  sudo e2label $LOOPDEV ignition

  mkdir tmpmount
  sudo mount $LOOPDEV tmpmount

  if [ ! -f config.fcc ]; then
    write_ignition > config.fcc
    [ -f config.fcc ] || error
  fi
  butane --strict --pretty config.fcc > config.ign || error

  if [ ! -f script ]; then
    write_combustion > script
    [ -f script ] || error
  fi

  sudo mkdir tmpmount/ignition || error
  sudo cp -a config.ign tmpmount/ignition/ || error
  sudo mkdir tmpmount/combustion || error
  sudo cp -a script tmpmount/combustion/ || error

  ignition_volume_prep_cleanup
  mv "$CONF_IMG" "$OUTPUT_DIR/"
}

ignition_volume_prep_cleanup() {
  if [ -d tmpmount ]; then
    sudo umount tmpmount
    sudo rmdir tmpmount
  fi
  if [ -n "$LOOPDEV" ]; then
    sudo losetup --detach $LOOPDEV
    LOOPDEV=""
  fi
  if [ -f "config.ign" ]; then
    rm config.ign
  fi
}

qcow_prep() {
  if [ ! -f "$QEMU_IMG" ]; then
    if $DOWNLOAD_QCOW; then
      echo "* download '$QEMU_IMG'"
      wget "${DISTRO_URL_BASE}${QEMU_IMG}" || error
    else
      if [ ! -f "$DISTRO_RAW" ]; then

        if [ ! -f "$DISTRO_RAWXZ" ]; then
          echo "* download '$DISTRO_RAWXZ'"
          wget "$DISTRO_FULL_URL" || error
        fi

        echo "* decompress raw image"
        xz -d "$DISTRO_RAWXZ" || error
      fi

      echo "* convert to qcow2 img"
      qemu-img convert -f raw -O qcow2 "$DISTRO_RAW" "${QEMU_IMG}" || error
    fi
  fi
  cp "${QEMU_IMG}" "${OUTPUT_DIR}/${QEMU_IMG}"
  qemu-img resize "${OUTPUT_DIR}/${QEMU_IMG}" "$VM_DISKSIZE"
  echo "* qcow image ready: $QEMU_IMG"
}

create_vm() {
  local uuid=$(uuidgen) || error
  local vmdisk="${uuid}-${MICRO_OS}.qcow2"
  local vmconf="${uuid}-config.img"
  local remote_option=""

  if [ -z "$REMOTE_KVM" ]; then
    sudo cp -a "${OUTPUT_DIR}/${QEMU_IMG}" "${VM_STORE}/${vmdisk}" || error
    sudo cp -a "${OUTPUT_DIR}/${CONF_IMG}" "${VM_STORE}/${vmconf}" || error
  else
    scp "${OUTPUT_DIR}/${QEMU_IMG}" "root@${REMOTE_KVM}:${VM_STORE}/${vmdisk}" || error
    scp "${OUTPUT_DIR}/${CONF_IMG}" "root@${REMOTE_KVM}:${VM_STORE}/${vmconf}" || error
    remote_option="--connect=qemu+ssh://root@${REMOTE_KVM}/system"
  fi

  sudo virt-install $remote_option \
    -n "${MICRO_OS}-$uuid" --osinfo=slem5.3 --memory="$VM_MEMORY" --vcpus="$VM_CORES" \
    --disk path="${VM_STORE}/${vmdisk}",bus=virtio --import \
    --disk path="${VM_STORE}/${vmconf}" \
    --graphics "$VM_GRAPHICS" \
    --network network="$VM_NETWORK" \
    --autoconsole "$VM_AUTOCONSOLE"
}

get_kubeconfig() {
  local ip="$1"

  scp root@$ip:/etc/rancher/k3s/k3s.yaml ./ > /dev/null || error
  sed -i "s/127.0.0.1/${ip}/g" k3s.yaml || error
  chmod 600 k3s.yaml || error
  echo "DONE: k3s.yaml retrieved successfully"
  echo "      you may want to:"
  echo "export KUBECONFIG=$PWD/k3s.yaml"
}

deploy_rancher() {
  local ip=$(kubectl get nodes -o=jsonpath='{.items[0].metadata.annotations.k3s\.io/internal-ip}') || error
  [ -z "$ip" ] && error "cannot retrieve cluster node ip"

  echo "* add helm repos"
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest || error
  helm repo add jetstack https://charts.jetstack.io || error
  helm repo update || error

  echo "* deploy cert-manager"
  kubectl create namespace cattle-system

  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.11.0/cert-manager.crds.yaml || error

  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.11.0 || error

  echo "* deploy rancher"
  # For Kubernetes v1.25 or later, set global.cattle.psp.enabled to false.
  local rancherOpts="--namespace cattle-system"
  [ -n "$RANCHER_VER" ] && rancherOpts="$rancherOpts --version $RANCHER_VER"

  helm install rancher rancher-latest/rancher \
  $rancherOpts \
  --set hostname=${ip}.sslip.io \
  --set replicas=1 \
  --set global.cattle.psp.enabled=false \
  --set bootstrapPassword="$RANCHER_PWD" || error

  echo "Rancher URL: https://${ip}.sslip.io"
}

help() {
  cat << EOF
Usage:
  ${0//*\/} CMD

  list of commands (CMD):
    artifacts         # downloads leapmicro release and creates a qcow2 image and ignite/combustion config volume (ignite.img)
                      # if config files are not found ("config" was not called before), it generates them first
    config            # just creates ignite (ignite.fcc) and combustion (script) source config files (warning: overwrites present files)
    create            # creates a VM backed up by the disks created by "artifacts", with VM_MEMORY memory and VM_CORES vcpus.
                      # if the artifacts folder is not found, calls "artifacts" first to generate the required disks
    delete [all]      # delete the generated artifacts; with 'all' deletes also config files
    getkubeconf <IP>  # get the kubeconfig file from a k3s host identified by the <IP> ip address
    deployrancher     # install Rancher via Helm chart (requires helm binary already installed)

  supported env vars:
    ENVC                # the environment config file to be imported if present (default: '\$HOME/.elemental/config)
                        # set to 'skip' to skip importing env variable declarations from any file
    MICRO_OS            # OS to install, 'leapmicro' or 'microOS' (default: 'leapmicro')
    SKIP_K3S            # boolean, skip k3s installation on 'true' (default: 'false')
    INSTALL_K3S_EXEC    # k3s installation options (default: 'server --write-kubeconfig-mode=644')
    INSTALL_K3S_VERSION # k3s installation version (default: 'v1.24.10+k3s1')
    CFG_HOSTNAME        # provisioned hostname (default: 'leapmicro')
    CFG_SSH_KEY         # the authorized ssh public key for remote access (default: not set)
    CFG_ROOT_PWD        # the root password of the installed system (default: 'elemental')
    RANCHER_PWD         # the admin password for rancher deployment (default: 'rancher4elemental')
    RANCHER_VER         # Rancher version to install (default picks up the latest)
    REMOTE_KVM          # the hostname/ip address of the KVM host if not using the local one (requires root access)
    VM_AUTOCONSOLE      # auto start console for the leapmicro K3s VM (default: text)
    VM_CORES            # number of vcpus assigned to the leapmicro K3s VM (default: '2')
    VM_DISKSIZE         # desired storage size in GB of the leapmicro K3s VM (default: '30')
    VM_GRAPHICS         # graphical display configuration for the leapmicro K3s VM (default: 'spice')
    VM_MEMORY           # amount of RAM assigned to the leapmicro K3s VM in MiB (default: '4096')
    VM_NETWORK          # virtual network (default: 'default')
    VM_STORE            # path where to put the disks for the leapmicro K3s VM (default: 'var/lib/libvirt/images')
EOF

  exit 0
}

case ${1} in

  artifacts)
    sudo echo ""
    if [ ! -d "$OUTPUT_DIR" ]; then
      mkdir "$OUTPUT_DIR" || error
    fi

    qcow_prep
    ignition_volume_prep
    ;;

  config)
    create_config_files
    ;;

  create)
    sudo echo ""
    if [ ! -d "$OUTPUT_DIR" ]; then
      mkdir "$OUTPUT_DIR" || error
    fi

    [ ! -f "$OUTPUT_DIR/$QEMU_IMG" ] && qcow_prep
    if [ ! -f "$OUTPUT_DIR/$CONF_IMG" ]; then
      ignition_volume_prep
    else
      echo "WARNING: found '$OUTPUT_DIR/$CONF_IMG', skip rebuild of ignition/combustion volume"
    fi

    create_vm
    ;;

  delete)
    rm -rf "$OUTPUT_DIR"
    if [ "${2}" = "all" ]; then
      rm -rf config.fcc script
    fi
    ;;

  getkubeconf|getk)
    IP=${2}
    if [ -z "$IP" ]; then
      error "ip address required but missing"
    fi
    get_kubeconfig "$IP"
    ;;

  deployrancher|rancher)
    deploy_rancher
    ;;

  *)
    help
    ;;

esac
