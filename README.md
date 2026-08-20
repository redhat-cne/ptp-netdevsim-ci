# ptp-netdevsim-ci

Shared GitHub Actions netdevsim CI for PTP operator repositories.

Operator trees (upstream monorepo, downstream OpenShift releases) call this
repo's reusable workflow at `@main` instead of copying `scripts/run-on-vm.sh`
and `ptp-tools/` into each release branch.

Prow jobs and `test/` stay in the operator repositories.

## Call from an operator PR

```yaml
name: "ptp-operator: netdevsim CI"
on:
  pull_request:
  workflow_dispatch:

jobs:
  netdevsim-ci:
    uses: redhat-cne/ptp-netdevsim-ci/.github/workflows/netdevsim.yml@main
```

Optional inputs (defaults are the caller repository and SHA):

- `operator-repository` — `owner/name`
- `operator-ref` — git ref or SHA

The workflow:

1. Checks out this repository (`scripts/` + `ptp-tools/`).
2. Checks out the operator PR (`sources` + `test/` + `config/`).
3. Clones [redhat-cne/netdevsim-dkms](https://github.com/redhat-cne/netdevsim-dkms) for DKMS modules.
4. Runs `scripts/run-on-vm.sh` with `OPERATOR_ROOT` pointing at the operator checkout.

## Layout

| Path | Role |
|------|------|
| `.github/workflows/netdevsim.yml` | Reusable `workflow_call` |
| `scripts/` | Kind/netdevsim helpers (`run-on-vm.sh`, `run-tests.sh`, `ptp-vrt/`, …) |
| `ptp-tools/` | Test image Dockerfiles + Makefile (`print-values`) |

Image builds use `OPERATOR_ROOT` as the podman context so Dockerfiles `COPY`
`pkg/linuxptp-daemon/`, `pkg/cloud-event-proxy/`, `bindata/`, and
`must-gather/` from the operator PR. Conformance tests run from
`$OPERATOR_ROOT/test/conformance`.

## Local run

```bash
export OPERATOR_ROOT=/path/to/ptp-operator
sudo ./scripts/run-on-vm.sh --dkms "$VM_IP"
```

When these scripts are overlaid into an operator checkout (see
`fetch-upstream-ci.sh` in the monorepo generator), `OPERATOR_ROOT` defaults to
that tree.
