# elemental-dev-scripts
Scripts for quick testing during development

**leapmicrok3s.sh**: create a VM based on leapmicro with k3s installed.
Optionally deploy Rancher on it.

**elemental-install.sh**: build Elemental Operator from sources, build and publish required container images and install it via helm on the current cluster pointed by kubeconfig.

**elemental-workloads.sh**: quickly create, check and install Elemental resources on the current cluster pointed by kubeconfig.

**elemental-vms.sh**: create (through virt-install) a variable number of vms booted from the ISO image file passed as an argument.
Use to create Elemental clusters quickly from an Elemental Seed Image.