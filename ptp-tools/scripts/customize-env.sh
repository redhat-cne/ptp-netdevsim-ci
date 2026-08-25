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

# When ENABLE_CEPV2=true, deploy Cloud Event Proxy v2 (EVENT_PROXY_IMAGE).
# Omitted/empty keeps CEPv1 sidecar-only behavior.
EVENT_PROXY_IMAGE=""
if [[ "${ENABLE_CEPV2:-}" == "true" ]]; then
  EVENT_PROXY_IMAGE="$IMG_PREFIX:cepv2"
fi

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
              value: "$IMG_PREFIX:cep"
            - name: EVENT_PROXY_IMAGE
              value: "$EVENT_PROXY_IMAGE"
            - name: IMAGE_PULL_POLICY
              value: "Always"
EOF
