#!/bin/bash
IMG_PREFIX=$1
ENV_PATH=$2

# Get RELEASE_VERSION dynamically from the operator checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_ROOT="${OPERATOR_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
VERSION_FILE="${OPERATOR_ROOT}/version/version.go"
if [ -f "$VERSION_FILE" ]; then
  RELEASE_VERSION=$(grep 'Version = ' "$VERSION_FILE" | sed 's/.*"\(.*\)".*/\1/')
  RELEASE_VERSION="v${RELEASE_VERSION}"
else
  RELEASE_VERSION="v5.0.0"
fi

# Upstream main dropped SideCarV2 and requires SIDECAR_EVENT_IMAGE to be CEPv2.
# Older operators still use CEPv1 on SIDECAR and optional CEPv2 on EVENT_PROXY_IMAGE.
CONTROLLER="${OPERATOR_ROOT}/controllers/ptpoperatorconfig_controller.go"
SIDECAR_EVENT_IMAGE="$IMG_PREFIX:cep"
EVENT_PROXY_IMAGE=""
if [[ -f "$CONTROLLER" ]] && ! grep -q 'SideCarV2' "$CONTROLLER"; then
  SIDECAR_EVENT_IMAGE="$IMG_PREFIX:cepv2"
elif [[ "${ENABLE_CEPV2:-}" == "true" ]]; then
  EVENT_PROXY_IMAGE="$IMG_PREFIX:cepv2"
fi
LINUXPTP_VERBOSITY="${LINUXPTP_VERBOSITY:-10}"

cat <<EOF > $ENV_PATH/env.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ptp-operator
  namespace: openshift-ptp
spec:
  template:
    spec:
      containers:
        - name: ptp-operator
          imagePullPolicy: Always
          env:
            - name: OPERATOR_NAME
              value: "ptp-operator"
            - name: RELEASE_VERSION
              value: "$RELEASE_VERSION"
            - name: LINUXPTP_DAEMON_IMAGE
              value: "$IMG_PREFIX:lptpd"
            - name: KUBE_RBAC_PROXY_IMAGE
              value: "$IMG_PREFIX:krp"
            - name: SIDECAR_EVENT_IMAGE
              value: "$SIDECAR_EVENT_IMAGE"
            - name: EVENT_PROXY_IMAGE
              value: "$EVENT_PROXY_IMAGE"
            - name: LINUXPTP_VERBOSITY
              value: "$LINUXPTP_VERBOSITY"
            - name: IMAGE_PULL_POLICY
              value: "Always"
EOF
