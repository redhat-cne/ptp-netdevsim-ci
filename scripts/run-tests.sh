#!/bin/bash
#
# Usage: ./run-tests.sh --kind <serial|parallel|both> --mode <modes> [OPTIONS]
#
# Required flags:
#   --kind <serial|parallel|both>   Test run kind
#   --mode <modes>                  Comma-separated test modes (e.g. oc,bc,dualnicbc)
#
# Optional flags:
#   --loglevel <level>              PTP log level (default: info)
#   --focus <regex>                 Pass through to ginkgo --focus (run matching specs only)
#   --linuxptp-daemon-image <url>   Full image URL for the linuxptp-daemon test pod.
#                                   When omitted, pmc pod tests are skipped.
#   --must-gather-image <url>       Full image URL for the ptp must-gather image.
#                                   When provided, must-gather runs for oc mode and on failure.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GINKGO_HEADLINE_REWRITE="${SCRIPT_DIR}/ginkgo-headline-rewrite.sh"
CI_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPERATOR_ROOT="${OPERATOR_ROOT:-}"
if [[ -z "${OPERATOR_ROOT}" ]]; then
  if [[ -d "${CI_ROOT}/test/conformance" ]]; then
    OPERATOR_ROOT="${CI_ROOT}"
  elif [[ -d "${CI_ROOT}/../operator/test/conformance" ]]; then
    OPERATOR_ROOT="$(cd "${CI_ROOT}/../operator" && pwd)"
  else
    echo "OPERATOR_ROOT must point at the operator checkout (test/conformance)" >&2
    exit 1
  fi
fi
OPERATOR_ROOT="$(cd "${OPERATOR_ROOT}" && pwd)"
export OPERATOR_ROOT
# shellcheck source=lib/operator-compat.sh
source "${SCRIPT_DIR}/lib/operator-compat.sh"

usage() {
  echo "Usage: $0 --kind <serial|parallel|both> --mode <modes> [--focus <regex>] [--loglevel <level>] [--linuxptp-daemon-image <url>] [--must-gather-image <url>]"
  exit 1
}

RUN_KIND=""
TEST_MODES_RAW=""
PTP_LOG_LEVEL="info"
LINUXPTP_DAEMON_IMAGE=""
MUST_GATHER_IMAGE=""
GINKGO_FOCUS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)
      RUN_KIND="$2"; shift 2 ;;
    --mode)
      TEST_MODES_RAW="$2"; shift 2 ;;
    --loglevel)
      PTP_LOG_LEVEL="$2"; shift 2 ;;
    --focus)
      [[ $# -ge 2 ]] || usage
      GINKGO_FOCUS="$2"; shift 2 ;;
    --linuxptp-daemon-image)
      LINUXPTP_DAEMON_IMAGE="$2"; shift 2 ;;
    --must-gather-image)
      MUST_GATHER_IMAGE="$2"; shift 2 ;;
    --debug-image)
      DEBUG_IMAGE="$2"; shift 2 ;;
    *)
      echo "Unknown flag: $1"
      usage ;;
  esac
done

if [[ -z "${RUN_KIND}" || -z "${TEST_MODES_RAW}" ]]; then
  echo "Error: --kind and --mode are required."
  usage
fi

JUNIT_OUTPUT_DIR="${JUNIT_OUTPUT_DIR:-/tmp/artifacts}"
JUNIT_OUTPUT_FILE="${JUNIT_OUTPUT_FILE:-unit_report.xml}"
export KUBECONFIG=${KUBECONFIG:-~/.kube/config}

# Match Ginkgo CLI to the operator tests; bump l2discovery-lib when helpers
# need PTPCaps fields that the pinned module tag does not ship.
ptp_align_l2discovery
ptp_install_ginkgo

mkdir -p "$JUNIT_OUTPUT_DIR"

export MAX_OFFSET_IN_NS="${MAX_OFFSET_IN_NS:-10000}"
export MIN_OFFSET_IN_NS="${MIN_OFFSET_IN_NS:--10000}"
export COLLECT_POD_LOGS="${COLLECT_POD_LOGS:-true}"
export LOG_ARTIFACTS_DIR="${LOG_ARTIFACTS_DIR:-${JUNIT_OUTPUT_DIR}/pod-logs}"

# With VRT, each Kind worker disciplines its own stand-in mock PHC instead of
# the shared host CLOCK_REALTIME, so slave phc2sys -a -r is safe.
# Enable RT update when:
#   - DISABLE_SLAVE_RT_UPDATE is set explicitly, or
#   - PTP_VRT_ENABLE=false → keep disabled, or
#   - DKMS_MODE=true (install/CI path), or
#   - VRT device files already exist from a prior cluster install
#     (re-running ./run-tests.sh without DKMS_MODE).
vrt_already_present() {
  local pod ns=openshift-ptp
  while read -r pod; do
    [[ -z "$pod" ]] && continue
    if kubectl exec -n "$ns" "$pod" -c linuxptp-daemon-container -- \
        test -s /var/run/vrt/device &>/dev/null; then
      return 0
    fi
  done < <(kubectl get pods -n "$ns" -l app=linuxptp-daemon \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

  local node
  for node in kind-netdevsim-worker kind-netdevsim-worker2 kind-netdevsim-worker3; do
    if podman exec "$node" test -s /var/run/ptp/vrt/device &>/dev/null ||
      docker exec "$node" test -s /var/run/ptp/vrt/device &>/dev/null; then
      return 0
    fi
  done
  return 1
}

if [[ -n "${DISABLE_SLAVE_RT_UPDATE:-}" ]]; then
  :
elif [[ "${PTP_VRT_ENABLE:-true}" != "true" ]]; then
  DISABLE_SLAVE_RT_UPDATE=true
elif [[ "${DKMS_MODE:-}" == "true" ]] || vrt_already_present; then
  DISABLE_SLAVE_RT_UPDATE=false
else
  DISABLE_SLAVE_RT_UPDATE=true
fi
echo "DisableAllSlaveRTUpdate=${DISABLE_SLAVE_RT_UPDATE}"

CONFIG_YAML="$(mktemp "${PTP_RUN_DIR:-/tmp}/ptp-config.XXXXXX.yaml")"
cat <<EOF >"${CONFIG_YAML}"
global:
  maxoffset: $MAX_OFFSET_IN_NS
  minoffset: $MIN_OFFSET_IN_NS
  holdover_timeout: 5
  DisableAllSlaveRTUpdate: ${DISABLE_SLAVE_RT_UPDATE}
EOF
export USE_CONTAINER_CMDS=
export PTP_TEST_CONFIG_FILE="${CONFIG_YAML}"
export PTP_LOG_LEVEL
# Use mod mode for tests - test module has its own go.mod
export GOFLAGS=-mod=mod
export KEEP_PTPCONFIG="${KEEP_PTPCONFIG:-true}"

export SKIP_INTERFACES="${SKIP_INTERFACES:-eth0}"

if [[ -n "${LINUXPTP_DAEMON_IMAGE}" ]]; then
  export IMAGE_REGISTRY="${LINUXPTP_DAEMON_IMAGE%/*}/"
  export CNF_TESTS_IMAGE="${LINUXPTP_DAEMON_IMAGE##*/}"
fi

TEST_MODES_RAW="$(ptp_filter_modes "${TEST_MODES_RAW}")"
if [[ -z "${TEST_MODES_RAW}" ]]; then
  echo "No supported clock modes requested for operator $(ptp_operator_version); skipping tests."
  exit 0
fi
IFS=',' read -r -a TEST_MODES <<< "${TEST_MODES_RAW}"

case "${RUN_KIND}" in
  serial|parallel|both) ;;
  *)
    echo "Invalid RUN_KIND value: ${RUN_KIND}. Use serial, parallel, or both."
    exit 2
    ;;
esac

MUST_GATHER_RAN=false

run_must_gather() {
  if [[ -z "${MUST_GATHER_IMAGE}" ]]; then
    echo "No must-gather image provided, skipping must-gather collection."
    return 0
  fi
  if [[ "${MUST_GATHER_RAN}" == "true" ]]; then
    return 0
  fi
  MUST_GATHER_RAN=true

  if ! command -v oc >/dev/null 2>&1 || ! oc adm --help >/dev/null 2>&1; then
    echo "oc adm is not available (kubectl-only PATH), skipping must-gather."
    return 0
  fi
  echo "Running must-gather with image: ${MUST_GATHER_IMAGE}"
  oc adm must-gather \
    --image="${MUST_GATHER_IMAGE}" \
    --node-name=kind-netdevsim-worker \
    --dest-dir="${JUNIT_OUTPUT_DIR}/must-gather" \
    --volume-percentage=95 \
    -- /usr/bin/gather --debug-image="${DEBUG_IMAGE}" || \
    echo "WARNING: must-gather collection failed"
}

on_exit() {
  local exit_code=$?
  rm -f "${CONFIG_YAML:-}"
  if [[ ${exit_code} -ne 0 ]]; then
    echo "Script failed with exit code ${exit_code}, collecting must-gather..."
    run_must_gather
  fi
}
trap on_exit EXIT

# Function to disable switch1 authentication
disable_switch_auth() {
    echo "Disabling switch1 authentication..."
    podman cp ptpswitchconfig.cfg switch1:/etc/ptp4l.conf
    podman exec switch1 systemctl restart ptp4l
    echo "✓ Switch1 authentication disabled"
}

# Function to enable switch1 authentication
enable_switch_auth() {
    echo "Configuring switch1 with PTP authentication..."

    # 1. Copy auth-enabled ptp4l.conf to switch1
    podman cp test-config/ptpswitchconfig_auth.cfg switch1:/etc/ptp4l.conf

    # 2. Create directory and copy security file
    podman exec switch1 mkdir -p /etc/ptp-secret-mount/ptp-security-conf
    podman cp test-config/ptp-security.conf switch1:/etc/ptp-secret-mount/ptp-security-conf/ptp-security.conf

    # 3. Restart ptp4l with authentication enabled
    podman exec switch1 systemctl restart ptp4l || {
    echo "WARNING: systemctl restart failed, trying pkill..."
    podman exec switch1 pkill ptp4l 2>/dev/null || true
    sleep 2
}

    echo "✓ Switch1 configured with authentication"
}

disable_switch_auth

systemctl stop chronyd 2>/dev/null || systemctl stop chrony 2>/dev/null || true

set -e

run_ginkgo_suite() {
  local mode="$1"
  local suite_kind="$2"
  local suite_path
  suite_path="$(ptp_conformance_suite_path "${suite_kind}")"
  if [[ -z "${suite_path}" ]]; then
    echo "No ${suite_kind} conformance suite under ${OPERATOR_ROOT}/test/conformance; skipping."
    return 0
  fi

  local junit_base="${JUNIT_OUTPUT_FILE%.xml}"
  local ginkgo_args=()
  local skip_patterns=()
  local skip

  while IFS= read -r skip; do
    [[ -n "${skip}" ]] && skip_patterns+=("${skip}")
  done < <(ptp_kind_skip_patterns "${mode}")
  if [[ -z "${LINUXPTP_DAEMON_IMAGE}" ]]; then
    skip_patterns+=("Run pmc in a new pod on the slave node.*")
  fi

  if [[ "${PTP_GINKGO_MAJOR:-2}" == "1" ]]; then
    ginkgo_args+=(
      -keepGoing
      -v
      -outputdir="${JUNIT_OUTPUT_DIR}"
      -junitReport="${junit_base}_${mode}_${suite_kind}.xml"
    )
    if [[ -n "${GINKGO_FOCUS}" ]]; then
      ginkgo_args+=(-focus="${GINKGO_FOCUS}")
    fi
    for skip in "${skip_patterns[@]}"; do
      ginkgo_args+=(-skip="${skip}")
    done
  else
    ginkgo_args+=(
      --keep-going
      --flake-attempts="${FLAKE_ATTEMPTS:-2}"
      --output-dir="${JUNIT_OUTPUT_DIR}"
      --junit-report="${junit_base}_${mode}_${suite_kind}.xml"
      -v
    )
    if [[ -n "${GINKGO_FOCUS}" ]]; then
      ginkgo_args+=(--focus="${GINKGO_FOCUS}")
    fi
    for skip in "${skip_patterns[@]}"; do
      ginkgo_args+=(--skip="${skip}")
    done
  fi

  echo "Running ginkgo v${PTP_GINKGO_MAJOR:-2} ${suite_kind} mode=${mode} suite=${suite_path} operator=$(ptp_operator_version)"

  local ginkgo_rc
  set +e
  if [[ "${PTP_GINKGO_HEADLINE_REWRITE:-1}" != "0" ]] && [[ -f "${GINKGO_HEADLINE_REWRITE}" ]]; then
    case "${suite_kind}" in
      parallel)
        PTP_TEST_MODE="${mode}" ginkgo -p "${ginkgo_args[@]}" "${suite_path}" 2>&1 | bash "${GINKGO_HEADLINE_REWRITE}"
        ;;
      *)
        PTP_TEST_MODE="${mode}" ginkgo "${ginkgo_args[@]}" "${suite_path}" 2>&1 | bash "${GINKGO_HEADLINE_REWRITE}"
        ;;
    esac
    ginkgo_rc=${PIPESTATUS[0]}
  else
    case "${suite_kind}" in
      parallel)
        PTP_TEST_MODE="${mode}" ginkgo -p "${ginkgo_args[@]}" "${suite_path}"
        ;;
      *)
        PTP_TEST_MODE="${mode}" ginkgo "${ginkgo_args[@]}" "${suite_path}"
        ;;
    esac
    ginkgo_rc=$?
  fi
  set -e
  return "${ginkgo_rc}"
}

for mode in "${TEST_MODES[@]}"; do
  if [[ "${RUN_KIND}" == "serial" || "${RUN_KIND}" == "both" ]]; then
    run_ginkgo_suite "${mode}" "serial"
  fi
  if [[ "${RUN_KIND}" == "parallel" || "${RUN_KIND}" == "both" ]]; then
    run_ginkgo_suite "${mode}" "parallel"
  fi
done

# Run must-gather for oc mode
for mode in "${TEST_MODES[@]}"; do
  if [[ "${mode}" == "oc" ]]; then
    echo "OC mode detected, collecting must-gather..."
    run_must_gather
    break
  fi
done

# Configure switch1 for authentication testing
# kubectl apply -f test-config/ptp-security.yaml
# enable_switch_auth

# Run tests with authentication enabled
# tests with auth will be enabled once the ci-github tests can last more than 1 hour
# PTP_AUTH_ENABLED=true PTP_TEST_MODE=oc ginkgo --skip=".*The interfaces supporting ptp can be discovered correctly.*" --skip="Negative - run pmc in a new unprivileged pod on the slave node.*" -v --keep-going --output-dir=$JUNIT_OUTPUT_DIR --junit-report=$JUNIT_OUTPUT_FILE -v "$SUITE"/serial
