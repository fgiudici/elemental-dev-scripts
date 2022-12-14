#!/bin/bash

EO_NAME="elemental-operator"
EO_SRC="/home/fgiudici/go/src/github.com/rancher/elemental-operator"
EO_REPO="quay.io/fgiudici/elemental-operator"
EO_NS="cattle-elemental-system"
CHART_NAME=""


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
    pushd ${EO_SRC} > /dev/null 2>&1
    ls -t build/*.tgz | head -n 1
    popd > /dev/null 2>&1
}

is_operator_installed() {
    helm list --all-namespaces | grep $EO_NAME > /dev/null
}

build_docker() {
    echo "INFO: build elemental-operator docker image"
    pushd $EO_SRC
    REPO=$EO_REPO make build-docker-operator
    [ "$?" != "0" ] && fail_err "docker build failed"
    TAG=$(get_last_tag)
    docker push ${EO_REPO}:${TAG}
    [ "$?" != "0" ] && fail_err "image push to $EO_REPO failed"

    make chart
    [ "$?" != "0" ] && fail_err "error building chart"

    CHART_NAME=$(get_chart_name)
    popd
}

install_helm_chart() {
    pushd ${EO_SRC}
    kubectl create namespace ${EO_NS}
    set -x
    helm install -n ${EO_NS} --set image.repository=${EO_REPO} ${EO_NAME} ${CHART_NAME} --set debug=true
    set +x
    popd
}

if is_operator_installed; then
    echo "Removing already installed operator"

    helm uninstall -n cattle-elemental-system elemental-operator
fi

build_docker
install_helm_chart

echo elemental-operator helm chart installed

