# elemental-dev-scripts
Scripts for quick testing during development

## leapmicrok3s.sh
Creates a VM based on leapmicro with k3s installed. Optionally deploys Rancher on it.

Steps:
* ``leapmicrok3s.sh config``: creates butane and combustion config files ('config.bu' and 'script') based on config in env vars.
* ``leapmicrok3s.sh artifacts``: downloads latest leapmicro (or microOS) release and converts to a qcow2 image with specified disk size ($VM_DISKSIZE); creates a config image containing ignition and combustion files generated from the 'config' step.
* ``leapmicrok3s.sh create``: starts a VM through virt-install backed up by the disk images created in the previous step (artifacts).

## elemental-install.sh
* Builds Elemental Operator from sources.
* Builds and publish required container images.
* Installs them via helm on the current cluster pointed by kubeconfig.

## elemental-workloads.sh
Quickly creates, checks and installs Elemental resources on the current cluster pointed by kubeconfig.

## elemental-vms.sh
Creates (through virt-install) a variable number of vms booted from the ISO image file passed as an argument.

Use it to create Elemental clusters quickly from an Elemental Seed Image.
