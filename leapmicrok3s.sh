#!/bin/sh

OUTPUT_DIR="artifacts"
DISTRO_NAME="openSUSE-Leap-Micro.x86_64-Default"
DISTRO_URL_BASE="https://download.opensuse.org/distribution/leap-micro/5.4/appliances/"
CONF_IMG="ignition.img"

# you can set your custom vars permanently in $HOME/.elemental/config
: ${ENVC:="$HOME/.elemental/config"}
if [ "$ENVC" != "skip" -a -f "${HOME}/.elemental/config" ]; then
  . "$ENVC"
fi

: ${ROOT_PWD:="elemental"}
: ${SSH_KEY:=""}
: ${VM_STORE:="/var/lib/libvirt/images"}
: ${VM_MEMORY:="4096"}
: ${VM_CORES:="2"}
: ${VM_GRAPHICS:="spice"}
: ${VM_AUTOCONSOLE:="text"}
: ${INSTALL_K3S_EXEC:="server --write-kubeconfig-mode=644"}
: ${INSTALL_K3S_VERSION:="v1.24.10+k3s1"}

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

qcow_prep() {
  if [ ! -f "$QEMU_IMG" ]; then

    if [ ! -f "$DISTRO_RAW" ]; then

      if [ ! -f "$DISTRO_RAWXZ" ]; then
        echo "* download leapmicro"
        wget "$DISTRO_FULL_URL" || error
      fi

      echo "* decompress raw image"
      xz -d "$DISTRO_RAWXZ" || error
    fi

    echo "* convert to qcow2 img"
    qemu-img convert -f raw -O qcow2 "$DISTRO_RAW" "${OUTPUT_DIR}/${QEMU_IMG}" || error
  fi
  echo "* qcow image ready: $QEMU_IMG"
  echo
}

write_ignition() {
  ROOT_HASHED_PWD=$(openssl passwd -6 "$ROOT_PWD") || error

  cat << EOF
variant: fcos
version: 1.3.0

passwd:
    users:
      - name: root
        password_hash: "$ROOT_HASHED_PWD"
EOF

  if [ -n "$SSH_KEY" ]; then
    cat << EOF
storage:
  files:
    - path: /root/.ssh/authorized_keys
      contents:
        inline: "$SSH_KEY"
      mode: 0600
      overwrite: true
EOF

  fi
}

write_combustion() {
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

help() {
  cat << EOF
Usage:
  ${0//*\/} CMD

  list of commands (CMD):
    artifacts   # downloads leapmicro release and creates a qcow2 image and ignite/combustion config volume (ignite.img)
                # if config files are not found ("config" was not called before), it generates them first
    config      # just creates ignite (ignite.fcc) and combustion (script) source config files (warning: overwrites present files)
    create      # creates a VM backed up by the disks created by "artifacts", with VM_MEMORY memory and VM_CORES vcpus.
                # if the artifacts folder is not found, calls "artifacts" first to generate the required disks
    delete      # delete the generated artifacts
  supported env vars:
    ENVC                # the environment config file to be imported if present (default: '\$HOME/.elemental/config)
                        # set to 'skip' to skip importing env variable declarations from any file
    INSTALL_K3S_EXEC    # k3s installation options (default: 'server --write-kubeconfig-mode=644')
    INSTALL_K3S_VERSION # k3s installation version (default: 'v1.24.10+k3s1')
    ROOT_PWD            # the root password of the installed system (default: 'elemental')
    VM_AUTOCONSOLE      # auto start console for the leapmicro K3s VM (default: text)
    VM_CORES            # number of vcpus assigned to the leapmicro K3s VM (default: '2')
    VM_GRAPHICS         # graphical display configuration for the leapmicro K3s VM (default: 'spice')
    VM_MEMORY           # amount of RAM assigned to the leapmicro K3s VM in MiB (default: '4096')
    VM_STORE            # path where to put the disks for the leapmicro K3s VM (default: 'var/lib/libvirt/images')
EOF

  exit 0
}

create_vm() {
  local uuid=$(uuidgen) || error
  local vmdisk="${uuid}-leapmicro.qcow2"
  local vmconf="${uuid}-config.img"

  sudo cp -a "${OUTPUT_DIR}/${QEMU_IMG}" "${VM_STORE}/${vmdisk}" || error
  sudo cp -a "${OUTPUT_DIR}/${CONF_IMG}" "${VM_STORE}/${vmconf}" || error

  sudo virt-install \
    -n "leapmicro-$uuid" --osinfo=slem5.3 --memory="$VM_MEMORY" --vcpus="$VM_CORES" \
    --disk path="${VM_STORE}/${vmdisk}",bus=virtio --import \
    --disk path="${VM_STORE}/${vmconf}" \
    --graphics "$VM_GRAPHICS" \
    --autoconsole "$VM_AUTOCONSOLE"
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
    ;;

  *)
    help
    ;;

esac
