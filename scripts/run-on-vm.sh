#!/bin/bash
set -euo pipefail

export DKMS_MODE="${DKMS_MODE:-false}"
export GO111MODULE=on
# Stream child command output live (default: quiet, dump log only on failure).
# Override with --verbose or RUN_ON_VM_VERBOSE=true|1|yes.
RUN_ON_VM_VERBOSE="${RUN_ON_VM_VERBOSE:-false}"
TEST_MODES="oc,bc,dualnicbc,dualnicbcha,dualfollower"
RUN_PHASE="all"
REGISTRY_IP=""
TARBALL=""
KEEP_TMP=true

while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --dkms)    export DKMS_MODE=true; shift ;;
        --verbose) RUN_ON_VM_VERBOSE=true; shift ;;
        --mode)    TEST_MODES="$2"; shift 2 ;;
        --images)  RUN_PHASE="images"; shift ;;
        --deploy)  RUN_PHASE="deploy"; REGISTRY_IP="$2"; shift 2 ;;
        --load)    RUN_PHASE="load"; TARBALL="$2"; shift 2 ;;
        --clean-tmp) KEEP_TMP=false; shift ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

case "${RUN_ON_VM_VERBOSE}" in
  1|true|TRUE|yes|YES|on|ON) RUN_ON_VM_VERBOSE=true ;;
  *) RUN_ON_VM_VERBOSE=false ;;
esac
export RUN_ON_VM_VERBOSE

# CI_ROOT is this repo (scripts + ptp-tools). OPERATOR_ROOT is the operator
# checkout (sources, test/, config/). When scripts are overlaid into an
# operator tree for local testing, the two directories are the same.
CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${OPERATOR_ROOT:-}" ]]; then
  if [[ -f "${CI_ROOT}/go.mod" && -d "${CI_ROOT}/test/conformance" ]]; then
    OPERATOR_ROOT="${CI_ROOT}"
  elif [[ -f "${CI_ROOT}/../operator/go.mod" ]]; then
    OPERATOR_ROOT="$(cd "${CI_ROOT}/../operator" && pwd)"
  else
    echo "OPERATOR_ROOT must point at the operator checkout (sources + test/ + config/)" >&2
    exit 1
  fi
fi
OPERATOR_ROOT="$(cd "${OPERATOR_ROOT}" && pwd)"
export CI_ROOT OPERATOR_ROOT
export PTP_TOOLS_DIR="${PTP_TOOLS_DIR:-${CI_ROOT}/ptp-tools}"
# shellcheck source=lib/operator-compat.sh
source "${CI_ROOT}/scripts/lib/operator-compat.sh"

if [[ "$RUN_PHASE" == "all" || "$RUN_PHASE" == "deploy" ]]; then
  _filtered_modes="$(ptp_filter_modes "${TEST_MODES}")"
  if [[ -z "${_filtered_modes}" ]]; then
    echo "run-on-vm: no supported clock modes in '${TEST_MODES}' for operator $(ptp_operator_version); skipping Kind deploy/tests."
    exit 0
  fi
  if [[ "${_filtered_modes}" != "${TEST_MODES}" ]]; then
    echo "run-on-vm: running supported modes '${_filtered_modes}' (requested '${TEST_MODES}')"
  fi
  TEST_MODES="${_filtered_modes}"
fi

# Per-run temp directory shared by all child scripts.
export PTP_RUN_DIR="${CI_ROOT}/.local-runs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${PTP_RUN_DIR}"
cleanup_run_dir() {
  if [[ "${KEEP_TMP}" == false ]]; then
    rm -rf "${PTP_RUN_DIR}"
  else
    echo "Temp directory retained: ${PTP_RUN_DIR}"
  fi
}
trap cleanup_run_dir EXIT

RUN_ON_VM_LOG="${PTP_RUN_DIR}/run-on-vm.log"
: >"${RUN_ON_VM_LOG}"
exec > >(tee -a "${RUN_ON_VM_LOG}") 2>&1

VM_IP=$1
echo "run-on-vm: logging to ${RUN_ON_VM_LOG}"
echo "run-on-vm: CI_ROOT=${CI_ROOT} OPERATOR_ROOT=${OPERATOR_ROOT}"

COLOR_STEP='\033[1;36m'
COLOR_ERR='\033[1;31m'
COLOR_OK='\033[1;32m'
COLOR_GRAY='\033[90m'
COLOR_RESET='\033[0m'

RUN_ON_VM_STEP_HDR="${COLOR_STEP}STEP:${COLOR_RESET}"
RUN_ON_VM_STEP_CHILD_INDENT='  '
# run_quiet_with_log_dump_on_failure only prints on failure
RUN_ON_VM_PHASE_FAIL_PREFIX="${COLOR_ERR}FAIL "
RUN_ON_VM_PHASE_LOG_BEGIN_PREFIX="${COLOR_ERR}---- BEGIN "
RUN_ON_VM_PHASE_LOG_END_PREFIX="${COLOR_ERR}---- END "

# Same clock layout as Ginkgo's default GINKGO_TIME_FORMAT ("01/02/06 15:04:05.999", see onsi/ginkgo/v2/types).
log_ts() { date '+%m/%d/%y %H:%M:%S.%3N'; }

# Echo with indent only.
log_ind() { echo -e "${RUN_ON_VM_STEP_CHILD_INDENT}$*"; }

# Log the command, run it, print stdout/stderr with indent on each line.
run_ind() {
  local _rc
  "$@" 2>&1 | sed "s/^/${RUN_ON_VM_STEP_CHILD_INDENT}/"
  _rc=${PIPESTATUS[0]}
  return "${_rc}"
}

step() { echo -e "${COLOR_STEP}STEP:${COLOR_RESET} $* ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"; }

_ptp_tool_images=()

# Populate _ptp_tool_images from ptp-tools/Makefile VALUES via `make print-values`.
read_ptp_tool_images() {
  local _img
  _ptp_tool_images=()
  while IFS= read -r _img; do
    [[ -n "${_img}" ]] && _ptp_tool_images+=("${_img}")
  done < <(make -C "${PTP_TOOLS_DIR}" -s OPERATOR_ROOT="${OPERATOR_ROOT}" print-values)
  if ((${#_ptp_tool_images[@]} == 0)); then
    echo "No image values from ${PTP_TOOLS_DIR}/Makefile (target print-values)" >&2
    return 1
  fi
}

# Dockerfiles COPY from OPERATOR_ROOT (pkg/, bindata, must-gather). Stage
# CI-only paths (ptp-tools/extra, scripts/ptp-vrt) into that context.
stage_ptp_tools_build_context() {
  mkdir -p "${OPERATOR_ROOT}/ptp-tools/extra" "${OPERATOR_ROOT}/scripts/ptp-vrt"
  if [[ -d "${PTP_TOOLS_DIR}/extra" ]]; then
    cp -a "${PTP_TOOLS_DIR}/extra/." "${OPERATOR_ROOT}/ptp-tools/extra/"
  fi
  if [[ -d "${CI_ROOT}/scripts/ptp-vrt" ]]; then
    cp -a "${CI_ROOT}/scripts/ptp-vrt/." "${OPERATOR_ROOT}/scripts/ptp-vrt/"
  fi
}

# Run with stdout/stderr captured; no output on success, On failure, print the command log.
# With RUN_ON_VM_VERBOSE=true, stream output live (already teed to RUN_ON_VM_LOG).
run_quiet_with_log_dump_on_failure() {
  local log_tag="$1"
  shift

  local log_file
  log_file="$(mktemp "${PTP_RUN_DIR}/${log_tag// /_}.XXXXXX.log")"

  local rc
  if [[ "${RUN_ON_VM_VERBOSE}" == true ]]; then
    echo -e "${COLOR_GRAY}---- BEGIN ${log_tag} (verbose) ----${COLOR_RESET} ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
    set +e
    "$@" </dev/null
    rc=$?
    set -e
    echo -e "${COLOR_GRAY}---- END ${log_tag} (verbose, exit ${rc}) ----${COLOR_RESET} ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
    rm -f "${log_file}"
    return "${rc}"
  fi

  if "$@" >"${log_file}" 2>&1 </dev/null; then
    rc=0
  else
    rc=$?
  fi

  if [[ "${rc}" -eq 0 ]]; then
    rm -f "${log_file}"
    return 0
  fi

  echo -e "${COLOR_ERR}FAIL ${log_tag}:${COLOR_RESET} (exit code ${rc}) ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
  echo -e "${COLOR_ERR}  CMD:${COLOR_RESET} $*"
  echo -e "${COLOR_ERR}---- BEGIN ${log_tag} LOG ----${COLOR_RESET} ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
  cat "${log_file}"
  echo -e "${COLOR_ERR}---- END ${log_tag} LOG ----${COLOR_RESET} ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"
  rm -f "${log_file}"
  return "${rc}"
}

declare -A STEP_ROWS_DONE

# Print the initial "LABELS <image>" list
run_step_rows_begin() {
  STEP_ROWS_LABELS=("$@")
  STEP_ROWS_COUNT=${#STEP_ROWS_LABELS[@]}
  STEP_ROWS_DONE=()
  STEP_ROWS_TTY_REDRAW=0
  STEP_ROWS_MAX_LABEL_LEN=0

  # stdout is teed to RUN_ON_VM_LOG, so -t 1 is false in this script. Never
  # open /dev/tty: sudo login shells in GitHub Actions do not inherit
  # GITHUB_ACTIONS and /dev/tty is not a usable device.
  if [[ -t 1 && -z "${CI:-}${GITHUB_ACTIONS:-}${GITLAB_CI:-}${BUILD_ID:-}" ]]; then
    set +e
    exec 9>/dev/tty 2>/dev/null
    local _tty_rc=$?
    set -e
    if ((_tty_rc == 0)); then
      STEP_ROWS_TTY_REDRAW=1
    fi
  fi

  for _line in "${STEP_ROWS_LABELS[@]}"; do
    [[ ${#_line} -gt $STEP_ROWS_MAX_LABEL_LEN ]] && STEP_ROWS_MAX_LABEL_LEN=${#_line}
  done

  if [[ "${STEP_ROWS_TTY_REDRAW}" == 1 ]]; then
    for _line in "${STEP_ROWS_LABELS[@]}"; do
      printf '  %-*s\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}" >&9
    done
  else
    for _line in "${STEP_ROWS_LABELS[@]}"; do
      printf '  %-*s\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}"
    done
  fi
}

# Marks a row as done if the command completed, otherwise print the row.
run_step_row_done() {
  local completed_label="$1"
  STEP_ROWS_DONE["${completed_label}"]=1

  if [[ "${STEP_ROWS_TTY_REDRAW}" == 1 ]]; then
    # Cursor is on the line after the block; move up to the first row of this block.
    printf '\033[%dA' "${STEP_ROWS_COUNT}" >&9
    local _line
    for _line in "${STEP_ROWS_LABELS[@]}"; do
      printf '\033[2K\r' >&9
      if [[ "${STEP_ROWS_DONE["${_line}"]:-0}" == 1 ]]; then
        printf '  %-*s %bOK%b\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}" "${COLOR_OK}" "${COLOR_RESET}" >&9
      else
        printf '  %-*s\n' "${STEP_ROWS_MAX_LABEL_LEN}" "${_line}" >&9
      fi
    done

  else
    printf '  %-*s %bOK%b %b@ %s%b\n' \
      "${STEP_ROWS_MAX_LABEL_LEN}" "${completed_label}" \
      "${COLOR_OK}" "${COLOR_RESET}" \
      "${COLOR_GRAY}" "$(log_ts)" "${COLOR_RESET}"
  fi
}

run_step_rows_end() {
  if [[ "${STEP_ROWS_TTY_REDRAW}" == 1 ]]; then
    exec 9>&-
    STEP_ROWS_TTY_REDRAW=0
  fi
}

# Parallel `make -s podman-<verb>-<img>` for each image tag, with the same step-row UI as sequential work:
# print "<row_prefix> <img>" lines, run all makes concurrently, mark each row OK on completion.
run_ptp_tools_parallel_make_step_rows() {
  local row_prefix="$1"
  local make_prefix="$2"
  local fifo_tag="$3"
  shift 3
  local -a images=("$@")
  local n=${#images[@]}

  local -a rows=()
  local _img
  for _img in "${images[@]}"; do
    rows+=("${row_prefix} ${_img}")
  done
  run_step_rows_begin "${rows[@]}"

  local fifo="${PTP_RUN_DIR}/ptp-${fifo_tag}-done-$$.fifo"
  rm -f "${fifo}"
  mkfifo "${fifo}"
  exec 8<> "${fifo}"

  local -a pids=()
  local _i
  for _i in "${!images[@]}"; do
    (
      _img="${images[$_i]}"
      if run_quiet_with_log_dump_on_failure "${make_prefix}-${_img}" make -s OPERATOR_ROOT="${OPERATOR_ROOT}" "${make_prefix}-${_img}"; then
        echo "${_img}" >&8
      else
        echo "FAIL:${_img}" >&8
      fi
    ) &
    pids+=($!)
  done

  local done_count=0
  local failed=0
  local line
  while ((done_count < n)); do
    IFS= read -r line <&8 || {
      failed=1
      break
    }
    if [[ "${line}" == FAIL:* ]]; then
      failed=1
      break
    fi
    ((done_count++)) || true
    run_step_row_done "${row_prefix} ${line}"
  done

  if ((failed)); then
    local _pid
    for _pid in "${pids[@]}"; do
      kill "${_pid}" 2>/dev/null || true
    done
    for _pid in "${pids[@]}"; do
      wait "${_pid}" 2>/dev/null || true
    done
    exec 8>&-
    rm -f "${fifo}"
    run_step_rows_end
    exit 1
  fi

  local _pid
  for _pid in "${pids[@]}"; do
    wait "${_pid}"
  done
  exec 8>&-
  rm -f "${fifo}"
  run_step_rows_end
}

step "Switching to script directory"
cd "$(dirname "${BASH_SOURCE[0]}")"

log_ind "Now in: $(pwd) ${COLOR_GRAY}@ $(log_ts)${COLOR_RESET}"

export GOMAXPROCS=$(nproc)

step "Installing required tools"
run_quiet_with_log_dump_on_failure "install-tools" bash ./install-tools.sh

export BASHRCSOURCED=1
PS1="${PS1:-}" source ~/.bashrc


# ── Images phase (--images) ──────────────────────────────────────────
if [[ "$RUN_PHASE" == "images" ]]; then

    export IMG_PREFIX="$VM_IP/test"

    read_ptp_tool_images
    stage_ptp_tools_build_context
    step "Building and saving ptp-tools images"
    cd "${PTP_TOOLS_DIR}"
    run_ptp_tools_parallel_make_step_rows BUILD podman-build-and-save build-save "${_ptp_tool_images[@]}"
    cd -

    tar cf /tmp/ptp-images.tar -C /tmp/ptp-images .
    echo "Images saved to /tmp/ptp-images.tar ($(du -h /tmp/ptp-images.tar | cut -f1))"

fi

# ── Images + deploy (default) ───────────────────────────────────────
if [[ "$RUN_PHASE" == "all" ]]; then

    step "Deleting existing kind cluster and containers"
    run_quiet_with_log_dump_on_failure "kind-delete-cluster" kind delete cluster --name kind-netdevsim || true

    run_quiet_with_log_dump_on_failure "podman-rm-switch1" podman rm -f switch1 || true

    export IMG_PREFIX="$VM_IP/test"

    cd "${PTP_TOOLS_DIR}"
    read_ptp_tool_images
    stage_ptp_tools_build_context

    step "Pruning unused podman storage"
    run_quiet_with_log_dump_on_failure "podman-system-prune" podman system prune -af || true

    # clean is included in build step
    step "Building ptp-tools images"
    run_ptp_tools_parallel_make_step_rows BUILD podman-build build "${_ptp_tool_images[@]}"

    cd -

    step "Building kustomize"
    run_quiet_with_log_dump_on_failure "make-kustomize" make -C "${OPERATOR_ROOT}" kustomize

    step "Creating local registry"
    run_quiet_with_log_dump_on_failure "create-local-registry" ./create-local-registry.sh "$VM_IP"

    cd "${PTP_TOOLS_DIR}"
    run_ptp_tools_parallel_make_step_rows PUSH podman-push push "${_ptp_tool_images[@]}"
    cd -

fi

# ── Load phase (--load) ─────────────────────────────────────────────
if [[ "$RUN_PHASE" == "load" ]]; then

    export IMG_PREFIX="$VM_IP/test"

    mkdir -p "${PTP_RUN_DIR}/ptp-images-load"
    tar xf "$TARBALL" -C "${PTP_RUN_DIR}/ptp-images-load"

    step "Retagging images for local registry"
    TAGS=(lptpd cep ptpop krp openvswitch prometheus ptpmg debug)
    for t in "${TAGS[@]}"; do
        podman load -i "${PTP_RUN_DIR}/ptp-images-load/$t.tar"
    done

    OLD_PREFIX=$(podman images --format '{{.Repository}}:{{.Tag}}' | grep ":${TAGS[0]}$" | head -1 | sed "s/:${TAGS[0]}$//")
    if [[ "$OLD_PREFIX" != "$IMG_PREFIX" ]]; then
        for t in "${TAGS[@]}"; do
            podman tag "$OLD_PREFIX:$t" "$IMG_PREFIX:$t"
        done
    fi

    step "Building kustomize"
    run_quiet_with_log_dump_on_failure "make-kustomize" make -C "${OPERATOR_ROOT}" kustomize

    step "Creating local registry"
    run_quiet_with_log_dump_on_failure "create-local-registry" ./create-local-registry.sh "$VM_IP"

    for t in "${TAGS[@]}"; do
        podman push --quiet "$IMG_PREFIX:$t" "docker://$IMG_PREFIX:$t"
    done

fi

# ── Deploy phase (--deploy or default) ──────────────────────────────
if [[ "$RUN_PHASE" == "all" || "$RUN_PHASE" == "deploy" ]]; then

    if [[ "$RUN_PHASE" == "deploy" ]]; then
        export IMG_PREFIX="${REGISTRY_IP}/test"
    else
        export IMG_PREFIX="${IMG_PREFIX:-$VM_IP/test}"
    fi

    step "Deleting kind cluster and containers"
    run_quiet_with_log_dump_on_failure "kind-delete-cluster" kind delete cluster --name kind-netdevsim || true
    run_quiet_with_log_dump_on_failure "podman-rm-switch1" podman rm -f switch1 || true

    step "Starting kind cluster"
    run_step_rows_begin "Building kind cluster..."
    run_quiet_with_log_dump_on_failure "k8s-start" ./k8s-start.sh "$VM_IP"
    run_step_row_done "Building kind cluster..."
    run_step_rows_end

    step "Applying certificate manifests"
    run_quiet_with_log_dump_on_failure "kubectl-apply-certs" kubectl apply -f certs.yaml

    step "Waiting for TLS certificates to be ready"
    run_quiet_with_log_dump_on_failure "wait-cert-serving" ./retry.sh 60 5 kubectl wait certificate/serving-cert -n openshift-ptp --for=condition=Ready --timeout=5s
    run_quiet_with_log_dump_on_failure "wait-cert-daemon" ./retry.sh 60 5 kubectl wait certificate/serving-cert-daemon -n openshift-ptp --for=condition=Ready --timeout=5s

    step "Deploying ptp-operator manifests"
    cd "${PTP_TOOLS_DIR}"
    run_quiet_with_log_dump_on_failure "make-deploy-all" sh -c "make OPERATOR_ROOT=\"${OPERATOR_ROOT}\" deploy-all || true"
    cd -

    step "Patching webhook for cert-manager CA injection (kind)"
    run_quiet_with_log_dump_on_failure "retry-patch-webhook-ca" ./retry.sh 60 5 bash -c 'kubectl patch validatingwebhookconfiguration ptpconfig-validating-webhook-configuration --type=strategic --patch-file kind-webhook-ca-patch.yaml && kubectl wait -f kind-webhook-ca-patch.yaml --for=jsonpath={.webhooks[0].clientConfig.caBundle} --timeout=5s'

    step "Waiting for ptp-operator rollout"
    run_quiet_with_log_dump_on_failure "kubectl-rollout-status" kubectl rollout status deployment ptp-operator -n openshift-ptp

    # deploy-all may fail to create default while the webhook has no CA yet; the
    # operator's one-shot createDefault also does not retry. Re-apply after CA
    # injection so the patch below has an object to update.
    step "Ensuring default ptpoperatorconfig exists"
    run_quiet_with_log_dump_on_failure "retry-apply-ptpoperatorconfig" ./retry.sh 60 5 kubectl apply -n openshift-ptp -f "${OPERATOR_ROOT}/config/samples/ptp_v1_ptpoperatorconfig.yaml"

    # Patch ptpoperatorconfig - use emptyDir for storage (local-path PVCs can't be shared across DaemonSet nodes)
    step "Patching ptpoperatorconfig for event publishing"
    if ! kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "emptyDir"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}' 2>/dev/null; then
        echo "Events config failed (may not be supported in this release), trying basic config..."
        if ! kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}' 2>/dev/null; then
            echo "Events config not supported, using basic daemonNodeSelector only..."
            kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'
        fi
    fi

    step "Waiting for linuxptp-daemon rollout"
    run_quiet_with_log_dump_on_failure "retry-rollout-status" ./retry.sh 30 3 kubectl rollout status ds linuxptp-daemon -n openshift-ptp

    # Tests from main expect v2 event API for operator >= 4.18.
    # Branches that default to v1 but support v2 need explicit configuration.
    if grep -q 'DefaultApiVersion.*"1.0"' "${OPERATOR_ROOT}/controllers/ptpoperatorconfig_controller.go" 2>/dev/null; then
      if grep -q 'ApiVersion.*apiVersion' "${OPERATOR_ROOT}/api/v1/ptpoperatorconfig_types.go" 2>/dev/null; then
        echo "Operator defaults to v1 event API, switching to v2 for test compatibility"
        ./retry.sh 60 5 kubectl patch ptpoperatorconfig default -n openshift-ptp \
          --type=merge --patch '{"spec": {"ptpEventConfig": {"apiVersion": "2.0"}}}'
        ./retry.sh 30 3 kubectl rollout status ds linuxptp-daemon -n openshift-ptp
      fi
    fi

    step "Fixing Prometheus monitoring"
    run_quiet_with_log_dump_on_failure "fix-ptp-prometheus-monitoring" ./fix-ptp-prometheus-monitoring.sh

    step "Listing openshift-ptp pods"
    run_ind kubectl get pods -n openshift-ptp -o wide

    ./run-tests.sh --kind serial --mode "$TEST_MODES" \
      --linuxptp-daemon-image "$IMG_PREFIX:lptpd" \
      --must-gather-image "$IMG_PREFIX:ptpmg" \
      --debug-image "$IMG_PREFIX:debug"

fi
