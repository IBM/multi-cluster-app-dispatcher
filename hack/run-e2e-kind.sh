#!/bin/bash

export ROOT_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/..
export LOG_LEVEL=3
export CLEANUP_CLUSTER=${CLEANUP_CLUSTER:-1}
export CLUSTER_CONTEXT="--name test"
export IMAGE_NGINX="nginx:latest"
export IMAGE_BUSYBOX="busybox:latest"
export KIND_OPT=${KIND_OPT:=" --config ${ROOT_DIR}/hack/e2e-kind-config.yaml"}
export KA_BIN=_output/bin
export WAIT_TIME="20s"
export IMAGE_REPOSITORY_MCAD="${1}"
export IMAGE_TAG_MCAD="${2}"
export IMAGE_MCAD="${IMAGE_REPOSITORY_MCAD}:${IMAGE_TAG_MCAD}"

sudo apt-get update && sudo apt-get install -y apt-transport-https
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee -a /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubectl

# Download kind binary (0.2.0)
sudo curl -o /usr/local/bin/kind -L https://github.com/kubernetes-sigs/kind/releases/download/0.2.0/kind-linux-amd64
sudo chmod +x /usr/local/bin/kind

# check if kind installed
function check-prerequisites {
  echo "checking prerequisites"
  which kind >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo "kind not installed, exiting."
    exit 1
  else
    echo -n "found kind, version: " && kind version
  fi

  which kubectl >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo "kubectl not installed, exiting."
    exit 1
  else
    echo -n "found kubectl, " && kubectl version --short --client
  fi
  
  if [[ $IMAGE_REPOSITORY_MCAD == "" ]]
  then
    echo "No MCAD image was provided."
    exit 1
  elif [[ $IMAGE_TAG_MCAD == "" ]]
  then
    echo "No MCAD image tag was provided for: ${IMAGE_REPOSITORY_MCAD}."
    exit 1
  else
    echo -n "end to end test with ${IMAGE_MCAD}."
  fi
}

function kind-up-cluster {
  check-prerequisites
  echo "Running kind: [kind create cluster ${CLUSTER_CONTEXT} ${KIND_OPT}]"
  kind create cluster ${CLUSTER_CONTEXT} ${KIND_OPT} --wait ${WAIT_TIME}
  docker pull ${IMAGE_BUSYBOX}
  docker pull ${IMAGE_NGINX}
  docker pull ${IMAGE_MCAD}
  kind load docker-image ${IMAGE_NGINX} ${CLUSTER_CONTEXT}
  kind load docker-image ${IMAGE_BUSYBOX} ${CLUSTER_CONTEXT}
  kind load docker-image ${IMAGE_MCAD} ${CLUSTER_CONTEXT}
}

# clean up
function cleanup {
    killall -9 kube-batch
    kind delete cluster ${CLUSTER_CONTEXT}

    echo "===================================================================================="
    echo "=============================>>>>> Scheduler Logs <<<<<============================="
    echo "===================================================================================="

    cat scheduler.log
}

function kube-batch-up {
    cd ${ROOT_DIR}

    export KUBECONFIG="$(kind get kubeconfig-path ${CLUSTER_CONTEXT})"
    kubectl version

    # Install Helm Client
    curl https://raw.githubusercontent.com/kubernetes/helm/master/scripts/get > install-helm.sh
    chmod u+x install-helm.sh
    cat install-helm.sh
    ./install-helm.sh

    # Install Helm Server 
    kubectl -n kube-system create serviceaccount tiller
    kubectl create clusterrolebinding tiller --clusterrole cluster-admin --serviceaccount=kube-system:tiller
    helm init --service-account tiller
    sleep 15
    kubectl get pods --namespace kube-system | grep tiller

    helm version 
    helm list

    cd deployment

    helm install kube-arbitrator --namespace kube-system --wait --set resources.requests.cpu=1000m --set resources.requests.memory=1024Mi --set resources.limits.cpu=1000m --set resources.limits.memory=1024Mi --set image.repository=$IMAGE_REPOSITORY_MCAD --set image.tag=$IMAGE_TAG_MCAD --set image.pullPolicy=Always

    sleep 10
    kubectl get pods -n kube-system

    # start kube-batch
    nohup ${KA_BIN}/kube-batch --kubeconfig ${KUBECONFIG} --scheduler-conf=config/kube-batch-conf.yaml --logtostderr --v ${LOG_LEVEL} > scheduler.log 2>&1 &
}


trap cleanup EXIT

kind-up-cluster

kube-batch-up

cd ${ROOT_DIR}
go test ./test/e2e -v -timeout 30m