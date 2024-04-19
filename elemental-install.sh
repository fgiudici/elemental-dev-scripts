#!/bin/bash

VERSION="0.3.0"
ARGS="$1"
: ${EO_SRC:="${GOPATH}/src/github.com/rancher/elemental-operator"}
: ${EO_NAME:="elemental-operator"}
: ${EO_NAME_CRDS:="elemental-operator-crds"}
: ${REGISTRY:="quay.io/$USER"}
: ${OPERATOR_REPO:="elemental-operator"}
: ${SEEDIMG_REPO:="elemental-seedimage"}
: ${EO_OS_CHANNEL:="registry.opensuse.org/isv/rancher/elemental/dev/containers/rancher/elemental-channel"}
EO_NS="cattle-elemental-system"
CHART_NAME=""
CHART_NAME_CRDS=""

export REGISTRY_URL=$REGISTRY

fail_err() {
  msg="$1"
  echo "ERR: ${msg}"
  echo "INSTALLATION ABORTED!"
  exit 1
}

get_last_tag() {
  docker images --format '{{.Tag}}' | head -n 1
}

get_chart_name() {
  local local_ln=${1:-'1'}
  pushd ${EO_SRC} > /dev/null 2>&1
  ls -t build/*.tgz | sed -n "$local_ln p"
  popd > /dev/null 2>&1
}

is_operator_installed() {
  helm list --all-namespaces | grep $EO_NAME > /dev/null
}

build_docker() {
  echo "INFO: build elemental-operator docker image"
  pushd $EO_SRC
  REPO=$OPERATOR_REPO make build-docker-operator
  [ "$?" != "0" ] && fail_err "docker build failed"
  TAG=$(get_last_tag)
  docker push ${REGISTRY_URL}/${OPERATOR_REPO}:${TAG}
  [ "$?" != "0" ] && fail_err "image push to $OPERATOR_REPO failed"

  echo "INFO: build elemental-seedimage docker image"
  REPO_SEEDIMAGE=$SEEDIMG_REPO make build-docker-seedimage-builder
  [ "$?" != "0" ] && fail_err "docker seedimage build failed"
  # TAG is the same of elemental-operator, so directly use that
  docker push ${REGISTRY_URL}/${SEEDIMG_REPO}:${TAG}
  [ "$?" != "0" ] && fail_err "image push to $SEEDIMG_REPO failed"

  REPO=$OPERATOR_REPO REPO_SEEDIMAGE=$SEEDIMG_REPO make chart
  [ "$?" != "0" ] && fail_err "error building chart"

  CHART_NAME=$(get_chart_name)
  CHART_NAME_CRDS=$(get_chart_name "2")
  popd
}

install_helm_chart() {
  pushd ${EO_SRC}
  echo -e "\n*** Install $CHART_NAME_CRDS"
  set -x
  # HELM custom value install:
  # helm upgrade --create-namespace -n ${EO_NS} --install ${EO_NAME} ${CHART_NAME} --set image.repository=${OPERATOR_REPO} --set seedimage.repository=${SEEDIMG_REPO} --set debug=true
  # our generated helm chart has our custom values already set
  helm upgrade --create-namespace -n ${EO_NS} --install ${EO_NAME_CRDS} ${CHART_NAME_CRDS}
  set +x
  echo -e "\n*** Install $CHART_NAME"
  set -x
  helm upgrade --create-namespace -n ${EO_NS} --install ${EO_NAME} ${CHART_NAME} --set debug=true --set channel.image="$EO_OS_CHANNEL" --set channel.tag=latest
  set +x
  popd
}

help() {
  local CMD=${0//*\/}
  cat << EOF
Usage:
  ${CMD} [--uninstall]

  ${CMD} builds the Elemental Operator (chart and elemental-operator container), pushes the Elemental Operator container
  to a container registry and installs the Elemental Operator to the Rancher Cluster pointed by kubectl.
  The command has some hard requirements in order to work:
  - the sources for the Elemental Operator are available at the dir pointed by EO_SRC
  - all the required packages to build the Elemental Operator are already installed
  - docker is available
  - user has write access to a container registry pointed by OPERATOR_REPO
  - kubectl is pointing to a Rancher Cluster

  list of options:
    --uninstall # will first uninstall the current elemental-operator chart (otherwise it will be upgraded)
  supported evn vars:
    EO_SRC        # location of the github.com/rancher/elemental-operator sources (current: $EO_SRC)
    REGISTRY      # container registry of the OPERATOR_REPO and SEEDIMG_REPO repositories (current: $REGISTRY)
    OPERATOR_REPO # container repo where the elemental-operator container will be uploaded (current: $OPERATOR_REPO)
    SEEDIMG_REPO  # container repo where the elemental seedimage builder container will be uploaded (current: $SEEDIMG_REPO)
EOF

exit 0
}

if [ "$ARGS" = "--uninstall" ]; then
  if is_operator_installed; then
    echo "Removing already installed operator"
    helm uninstall -n cattle-elemental-system elemental-operator
  fi
elif [ -n "$ARGS" ]; then
  help
fi

build_docker
install_helm_chart

unset REGISTRY_URL
echo elemental-operator helm chart installed

