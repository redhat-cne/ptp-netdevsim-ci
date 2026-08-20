#!/bin/bash
set -x
set -euo pipefail

kubectl label node kind-netdevsim-control-plane node-role.kubernetes.io/control-plane=true --overwrite
kubectl label node kind-netdevsim-worker  node-role.kubernetes.io/master= --overwrite
kubectl label node kind-netdevsim-worker2 node-role.kubernetes.io/master= --overwrite
kubectl label node kind-netdevsim-worker3 node-role.kubernetes.io/master= --overwrite

kubectl label node kind-netdevsim-worker node-role.kubernetes.io/worker= --overwrite
kubectl label node kind-netdevsim-worker2 node-role.kubernetes.io/worker= --overwrite
kubectl label node kind-netdevsim-worker3 node-role.kubernetes.io/worker= --overwrite

# Required by config/samples/ptp_v1_ptpoperatorconfig.yaml daemonNodeSelector.
kubectl label node kind-netdevsim-worker feature.node.kubernetes.io/ptp-capable=yes --overwrite
kubectl label node kind-netdevsim-worker2 feature.node.kubernetes.io/ptp-capable=yes --overwrite
kubectl label node kind-netdevsim-worker3 feature.node.kubernetes.io/ptp-capable=yes --overwrite
