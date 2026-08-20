
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
