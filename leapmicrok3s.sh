#!/bin/sh

VERSION="0.4.1.1-devel"
OUTPUT_DIR="artifacts"
CONF_IMG="ignition.img"
DOWNLOAD_QCOW=false
TMP_BUTANE_CONFIG="config.bu"
TMP_IGNITION_CONFIG="config.ign"
TMP_COMBUSTION_SCRIPT="script"

# you can set your custom vars permanently in $HOME/.elemental/config
: ${ENVC:="$HOME/.elemental/config"}
if [ "$ENVC" != "skip" -a -f "$ENVC" ]; then
  . "$ENVC"
fi


: ${MICRO_OS:=leapmicro}
: ${SKIP_K3S:=false}
: ${CFG_ROOT_PWD:="elemental"}
: ${CFG_USER_NAME:="user"}
: ${CFG_USER_PWD:="elemental"}
: ${CFG_SSH_KEY:=""}
: ${CFG_HOSTNAME:="$MICRO_OS"}
: ${VM_STORE:="/var/lib/libvirt/images"}
: ${VM_DISKSIZE:="30"}
: ${VM_MEMORY:="4096"}
: ${VM_NETWORK:="network=default"}
: ${VM_CORES:="2"}
: ${VM_GRAPHICS:="spice"}
: ${VM_AUTOCONSOLE:="text"}
: ${INSTALL_K3S_EXEC:="server --write-kubeconfig-mode=644"}
: ${INSTALL_K3S_VERSION:="v1.28.13+k3s1"}
: ${RANCHER_PWD:="elemental"}
: ${RANCHER_VER:=""}
: ${RANCHER_REPO:="latest"}
: ${RANCHER_HOSTNAME:=""}
: ${REMOTE_KVM:=""}

case "$MICRO_OS" in
  leapmicro)
    DISTRO_NAME="openSUSE-Leap-Micro.x86_64-Default-qcow"
    DISTRO_URL_BASE="https://download.opensuse.org/distribution/leap-micro/6.0/appliances/"
    DOWNLOAD_QCOW=true
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
  USER_HASHED_PWD=$(openssl passwd -6 "$CFG_USER_PWD") || error

  cat << EOF
variant: fcos
version: 1.3.0

passwd:
    users:
      - name: root
        password_hash: "$ROOT_HASHED_PWD"
      - name: "$CFG_USER_NAME"
        home_dir: "/var/${CFG_USER_NAME}"
        password_hash: "$USER_HASHED_PWD"
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
  write_ignition > "$TMP_BUTANE_CONFIG"
  write_combustion > "$TMP_COMBUSTION_SCRIPT"
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

  write_ignition > "$TMP_BUTANE_CONFIG"
  [ -f "$TMP_BUTANE_CONFIG" ] || error
  butane --strict --pretty "$TMP_BUTANE_CONFIG" > "$TMP_IGNITION_CONFIG" || error

  write_combustion > "$TMP_COMBUSTION_SCRIPT"
  [ -f "$TMP_COMBUSTION_SCRIPT" ] || error

  sudo mkdir tmpmount/ignition || error
  sudo cp -a "$TMP_IGNITION_CONFIG" tmpmount/ignition/ || error
  sudo mkdir tmpmount/combustion || error
  sudo cp -a "$TMP_COMBUSTION_SCRIPT" tmpmount/combustion/ || error

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
  if [ -f ""$TMP_IGNITION_CONFIG"" ]; then
    rm "$TMP_IGNITION_CONFIG"
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
    -n "${MICRO_OS}-$uuid" --osinfo=slem5.4 --memory="$VM_MEMORY" --vcpus="$VM_CORES" \
    --disk path="${VM_STORE}/${vmdisk}",bus=virtio --import \
    --disk path="${VM_STORE}/${vmconf}" \
    --graphics "$VM_GRAPHICS" \
    --network "$VM_NETWORK" \
    --autoconsole "$VM_AUTOCONSOLE" $VM_CUSTOMOPTION
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

  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.crds.yaml || error

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.13.1 || error

  echo "* deploy rancher"
  # For Kubernetes v1.25 or later, set global.cattle.psp.enabled to false.
  local rancherOpts="--namespace cattle-system"
  if [ -n "$RANCHER_VER" ]; then
    case $RANCHER_VER in
      "Dev"|"dev"|"Devel"|"devel")
        rancherOpts="$rancherOpts --devel"
        ;;
      *)
        rancherOpts="$rancherOpts --version $RANCHER_VER"
	;;
    esac
  fi

  if [ "$RANCHER_HOSTNAME" = "" ]; then
    RANCHER_HOSTNAME="${ip}.sslip.io"
  fi

  helm install rancher rancher-${RANCHER_REPO}/rancher \
  $rancherOpts \
  --set hostname=${RANCHER_HOSTNAME} \
  --set replicas=1 \
  --set bootstrapPassword="$RANCHER_PWD" || error

  echo "Rancher URL: https://$RANCHER_HOSTNAME"
}

deploy_elemental() {
  local elem_ver="$1"

  case ${elem_ver} in
    Dev|dev|DEV)
    CHART_NAME_OPERATOR="oci://registry.opensuse.org/isv/rancher/elemental/dev/charts/rancher/elemental-operator-chart"
    [[ "$CHART_NAME_CRDS" == "$ELEMENTAL_OPERATOR_CRDS_CHART_NAME" ]] && \
        CHART_NAME_CRDS="oci://registry.opensuse.org/isv/rancher/elemental/dev/charts/rancher/elemental-operator-crds-chart"
    ;;
    Staging|staging|STAGING)
    CHART_NAME_OPERATOR="oci://registry.opensuse.org/isv/rancher/elemental/staging/charts/rancher/elemental-operator-chart"
    [[ "$CHART_NAME_CRDS" == "$ELEMENTAL_OPERATOR_CRDS_CHART_NAME" ]] && \
        CHART_NAME_CRDS="oci://registry.opensuse.org/isv/rancher/elemental/staging/charts/rancher/elemental-operator-crds-chart"
    ;;
    Stable|stable|STABLE)
    CHART_NAME_OPERATOR="oci://registry.suse.com/rancher/elemental-operator-chart"
    [[ "$CHART_NAME_CRDS" == "$ELEMENTAL_OPERATOR_CRDS_CHART_NAME" ]] && \
        CHART_NAME_CRDS="oci://registry.suse.com/rancher/elemental-operator-crds-chart"
    ;;
    *)
    echo "Elemental version '$elem_ver' not supported"
    echo "Supported Elemental charts values are: 'stable', 'staging' or 'dev'"
    exit 1
    ;;
  esac

  echo "Installing $elem_ver Elemental charts"
  helm upgrade --create-namespace -n cattle-elemental-system --install elemental-operator-crds $CHART_NAME_CRDS
  helm upgrade --create-namespace -n cattle-elemental-system --install elemental-operator $CHART_NAME_OPERATOR
}

help() {
  cat << EOF
Usage:
  ${0//*\/} CMD

  list of commands (CMD):
    artifacts             # downloads leapmicro release and creates a qcow2 image and ignite/combustion config volume (ignite.img)
                          # if config files are not found ("config" was not called before), it generates them first
    config                # just creates ignite (ignite.fcc) and combustion ("$TMP_COMBUSTION_SCRIPT") source config files (warning: overwrites present files)
    create                # creates a VM backed up by the disks created by "artifacts", with VM_MEMORY memory and VM_CORES vcpus.
                          # if the artifacts folder is not found, calls "artifacts" first to generate the required disks
    delete [all]          # delete the generated artifacts; with 'all' deletes also config files
    getkubeconf <IP>      # get the kubeconfig file from a k3s host identified by the <IP> ip address
    deployrancher         # install Rancher via Helm chart (requires helm binary already installed)
    elemental <RELEASE>   # install Elemental charts from the RELEASE channel (RELEASE could be 'stable', 'staging' or 'dev')

  supported env vars:
    ENVC                # the environment config file to be imported if present (default: '\$HOME/.elemental/config)
                        # set to 'skip' to skip importing env variable declarations from any file
    MICRO_OS            # OS to install, 'leapmicro' or 'microOS' (default: 'leapmicro')
    SKIP_K3S            # boolean, skip k3s installation on 'true' (default: 'false')
    INSTALL_K3S_EXEC    # k3s installation options (default: 'server --write-kubeconfig-mode=644')
    INSTALL_K3S_VERSION # k3s installation version (default: '$INSTALL_K3S_VERSION')
    CFG_HOSTNAME        # provisioned hostname (default: '$CFG_HOSTNAME')
    CFG_SSH_KEY         # the authorized ssh public key for remote access
    CFG_ROOT_PWD        # the root password of the installed system (default: '$CFG_ROOT_PWD')
    RANCHER_PWD         # the admin password for rancher deployment (default: '$RANCER_PWD')
    RANCHER_VER         # Rancher version to install (default picks up the latest stable)
    RANCHER_REPO        # Rancher helm chart repo to pick rancher from (default '$RANCHER_REPO')
    RANCHER_HOSTNAME    # Rancher hostname (default '\$IP.sslip.io')
    REMOTE_KVM          # the hostname/ip address of the KVM host if not using the local one (requires root access)
    VM_AUTOCONSOLE      # auto start console for the leapmicro K3s VM (default: '$VM_AUTOCONSOLE')
    VM_CORES            # number of vcpus assigned to the leapmicro K3s VM (default: '$VM_CORES')
    VM_DISKSIZE         # desired storage size in GB of the leapmicro K3s VM (default: '$VM_DISKSIZE')
    VM_GRAPHICS         # graphical display configuration for the leapmicro K3s VM (default: '$VM_GRAPHICS')
    VM_MEMORY           # amount of RAM assigned to the leapmicro K3s VM in MiB (default: '$VM_MEMORY')
    VM_NETWORK          # virtual network (default: '$VM_NETWORK')
    VM_STORE            # path where to put the disks for the leapmicro K3s VM (default: '$VM_STORE')
    VM_CUSTOMOPTION     # custom option appended to 'virt-install'

example:
  VM_STORE=/data/images/ VM_NETWORK="network=\$NETNAME,mac=52:54:00:00:01:fe" VM_MEMORY=8192 VM_CORES=4 ./leapmicrok3s.sh create
  VM_STORE=/data/images/ VM_NETWORK="bridge=br-dmz,mac=52:54:00:00:01:fe" VM_MEMORY=8192 VM_CORES=4 ./leapmicrok3s.sh create
  VM_STORE=/data/images/ VM_NETWORK="bridge=br-dmz,mac=52:54:00:00:01:fe" VM_MEMORY=8192 VM_CORES=4 ./leapmicrok3s.sh create VM_CUSTOMOPTION="--network bridge=br-lan,mac=52:54:00:10:22"

  leapmicrok3s.sh getkubeconf 192.168.122.2

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
      rm -rf "$TMP_BUTANE_CONFIG" "$TMP_COMBUSTION_SCRIPT"
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

  deployelemental|elemental|elem)
    deploy_elemental ${2}
    ;;
  *)
    help
    ;;

esac
