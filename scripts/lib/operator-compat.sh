#!/usr/bin/env bash
# Release-aware helpers for ptp-netdevsim-ci.
# Sourced by run-on-vm.sh, run-tests.sh, and install-tools.sh.
# Requires OPERATOR_ROOT to point at the operator checkout.

# Operator Version from version/version.go (e.g. 4.12.0). Empty if missing.
ptp_operator_version() {
  local f="${OPERATOR_ROOT:-}/version/version.go"
  if [[ -f "$f" ]]; then
    sed -n 's/.*Version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
    return 0
  fi
  printf '%s' "0.0.0"
}

# Return 0 if version A is strictly less than B (sort -V).
ptp_version_lt() {
  local a="$1" b="$2"
  [[ "$a" == "$b" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -1)" == "$a" ]]
}

ptp_mode_lc() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# True if the operator testconfig implements the reusable-workflow clock mode.
# oc/bc are present in every release that has conformance tests.
ptp_mode_supported() {
  local mode_lc tc
  mode_lc=$(ptp_mode_lc "$1")
  tc="${OPERATOR_ROOT}/test/pkg/testconfig/testconfig.go"

  case "$mode_lc" in
    oc | ordinaryclock | bc | boundaryclock)
      return 0
      ;;
    dualnicbc)
      [[ -f "$tc" ]] || return 1
      grep -qE 'DualNICBoundaryClockString[[:space:]]*=' "$tc" \
        || grep -qE '"DualNICBC"' "$tc"
      ;;
    dualnicbcha)
      # DualNICBCHA exists from OCP 4.21+. Unknown mode falls back to OC and
      # burns 40–60m on the wrong suite.
      [[ -f "$tc" ]] || return 1
      grep -qE 'DualNICBoundaryClockHAString[[:space:]]*=' "$tc" \
        || grep -qE '"DualNICBCHA"' "$tc"
      ;;
    dualfollower)
      # DualFollower exists from OCP 4.19+.
      [[ -f "$tc" ]] || return 1
      grep -qE 'DualFollowerClockString[[:space:]]*=' "$tc" \
        || grep -qE '"DualFollower"' "$tc"
      ;;
    *)
      return 0
      ;;
  esac
}

# Filter a comma-separated mode list to those implemented by this operator.
# Unsupported modes are logged to stderr. Prints the kept list on stdout.
ptp_filter_modes() {
  local raw="$1"
  local out="" m rest
  rest="$raw"
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == *,* ]]; then
      m="${rest%%,*}"
      rest="${rest#*,}"
    else
      m="$rest"
      rest=""
    fi
    m="${m#"${m%%[![:space:]]*}"}"
    m="${m%"${m##*[![:space:]]}"}"
    [[ -z "$m" ]] && continue
    if ptp_mode_supported "$m"; then
      if [[ -n "$out" ]]; then
        out="${out},${m}"
      else
        out="$m"
      fi
    else
      echo "SKIP: clock mode '${m}' is not implemented in this operator (version $(ptp_operator_version))" >&2
    fi
  done
  printf '%s' "$out"
}

# Directory that owns the test Go module (test/go.mod or the operator root).
ptp_test_module_dir() {
  if [[ -n "${OPERATOR_ROOT:-}" && -f "${OPERATOR_ROOT}/test/go.mod" ]]; then
    printf '%s' "${OPERATOR_ROOT}/test"
  else
    printf '%s' "${OPERATOR_ROOT}"
  fi
}

# Print the ginkgo suite directory for serial or parallel, or empty if absent.
# 4.12 keeps tests in test/conformance/ (no serial/ subdirectory).
ptp_conformance_suite_path() {
  local kind="$1"
  local base="${OPERATOR_ROOT}/test/conformance"
  [[ -d "$base" ]] || return 0

  if [[ "$kind" == "parallel" ]]; then
    if compgen -G "${base}/parallel/*_test.go" >/dev/null; then
      printf '%s' "${base}/parallel"
    fi
    return 0
  fi

  if compgen -G "${base}/serial/*_test.go" >/dev/null; then
    printf '%s' "${base}/serial"
  elif compgen -G "${base}/*_test.go" >/dev/null; then
    printf '%s' "${base}"
  fi
}

# Install the Ginkgo CLI that matches the operator tests (v1 vs v2 + module version).
# Sets PTP_GINKGO_MAJOR to 1 or 2.
ptp_install_ginkgo() {
  local dir ver
  dir=$(ptp_test_module_dir)

  if grep -Rql --include='*_test.go' 'github.com/onsi/ginkgo/v2' \
      "${OPERATOR_ROOT}/test/conformance" 2>/dev/null; then
    ver=$(awk '/github.com\/onsi\/ginkgo\/v2/ {print $2; exit}' \
      "${dir}/go.mod" "${OPERATOR_ROOT}/go.mod" 2>/dev/null | head -1)
    ver="${ver:-v2.23.3}"
    echo "Installing ginkgo ${ver} (v2 CLI, module ${dir})"
    (cd "${dir}" && GOFLAGS=-mod=mod go install "github.com/onsi/ginkgo/v2/ginkgo@${ver}")
    export PTP_GINKGO_MAJOR=2
  else
    ver=$(awk '/github.com\/onsi\/ginkgo v1/ {print $2; exit}' \
      "${dir}/go.mod" "${OPERATOR_ROOT}/go.mod" 2>/dev/null | head -1)
    ver="${ver:-v1.16.5}"
    echo "Installing ginkgo ${ver} (v1 CLI — 4.12 and similar)"
    GOFLAGS=-mod=mod go install "github.com/onsi/ginkgo/ginkgo@${ver}"
    export PTP_GINKGO_MAJOR=1
  fi
}

# test/go.mod sometimes pins an old l2discovery-lib while helpers/tests already
# need PTPCaps.PhcIndex (v0.1.0+) or solver.StepHasGNSSDevice (v0.1.3+).
ptp_align_l2discovery() {
  local dir helper need_ver=""
  helper="${OPERATOR_ROOT}/test/pkg/ptphelper/ptphelper.go"
  dir=$(ptp_test_module_dir)
  [[ -f "${dir}/go.mod" ]] || return 0
  grep -q 'github.com/redhat-cne/l2discovery-lib' "${dir}/go.mod" || return 0

  if grep -Rql --include='*.go' 'StepHasGNSSDevice' "${OPERATOR_ROOT}/test" 2>/dev/null; then
    need_ver="v0.1.4"
  elif [[ -f "$helper" ]] && grep -q 'IfPTPCaps.PhcIndex' "$helper"; then
    need_ver="v0.1.4"
  else
    return 0
  fi

  if grep -qE "l2discovery-lib ${need_ver}([[:space:]]|$)" "${dir}/go.mod"; then
    return 0
  fi
  # Anything older than need_ver (including v0.0.x and v0.1.0–v0.1.2).
  if grep -qE 'l2discovery-lib v0\.(0\.|1\.[012]([[:space:]]|$))' "${dir}/go.mod"; then
    echo "Bumping l2discovery-lib to ${need_ver} (required by current tests)"
    (cd "${dir}" && GOFLAGS=-mod=mod go get "github.com/redhat-cne/l2discovery-lib@${need_ver}")
  fi
}

# Kind/netdevsim skip regexes, one per line. Mode-specific extras are included.
ptp_kind_skip_patterns() {
  local ver mode
  ver=$(ptp_operator_version)
  mode=$(ptp_mode_lc "${1:-}")

  # Already skipped by historical netdevsim CI (l2 vs ptp API mismatch on Kind).
  echo '.*The interfaces supporting ptp can be discovered correctly.*'
  echo 'Negative - run pmc in a new unprivileged pod on the slave node.*'

  # Kind has no OpenShift ClusterOperator; older tests Require a non-empty OCP version.
  echo '.*Should retrieve the details of hardwares for the Ptp.*'
  # Outage recovery DaemonSet is not deployed on Kind (panic / DS not found).
  echo '.*The slave node network interface is taken down and up.*'
  # Reboot is not meaningful on Kind workers.
  echo '.*The slave node is rebooted and discovered and in sync.*'
  # ptpPods is only listed in the discovery Context BeforeEach. Skipping that
  # spec leaves ptpPods nil, and this ClockSync It panics on ptpPods.Items.
  echo '.*PTP daemon apply match rule based on nodeLabel.*'

  # 4.12–4.15: event sidecar / prometheus scrape / UDS sharing are not reliable
  # on Kind with the images this workflow builds. Clock-sync / profile-priority
  # also fail on OC (not only BC) before 4.16.
  if ptp_version_lt "$ver" "4.16.0"; then
    echo '.*Should check for ptp events.*'
    echo '.*PTP metric is present.*'
    echo '.*on slave.*'
    echo '.*Should all be reported by prometheus.*'
    echo '.*Should be able to sync using a uds.*'
    echo '.*Slave can sync to master.*'
    echo '.*Downstream slave can sync to BC master.*'
    echo '.*Can provide a profile with higher priority.*'
  fi

  # 4.20 DualFollower discovers correctly but port-down role flip is unstable on netdevsim.
  case "$ver" in
    4.20 | 4.20.*)
      if [[ "$mode" == "dualfollower" ]]; then
        echo '.*Dual follower can sync when one follower port goes down.*'
      fi
      ;;
  esac
}
