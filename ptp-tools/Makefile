# OPERATOR_ROOT is the operator checkout used as the podman build context
# (pkg/, bindata, config/, must-gather). Defaults to the parent of ptp-tools,
# which is correct when this Makefile is overlaid into an operator tree.
OPERATOR_ROOT ?= $(abspath ..)
PTP_TOOLS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

LOCALBIN ?= $(OPERATOR_ROOT)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)/x86_64/

# Allow PLATFORM to be overridden via environment variable
# If not provided, auto-discover the platform
ifndef PLATFORM
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m)

# Normalize architecture names
ifeq ($(ARCH),x86_64)
  ARCH := amd64
endif
ifeq ($(ARCH),aarch64)
  ARCH := arm64
endif

PLATFORM := $(OS)/$(ARCH)
endif

## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize

IMG_PREFIX ?= quay.io/<your user id here>/<your image name>
SAVE_DIR ?= /tmp/ptp-images

ifdef GITHUB_ACTIONS
CACHE_FLAG ?=
else
CACHE_FLAG ?= --no-cache
endif

VALUES = lptpd cep ptpop krp openvswitch prometheus ptpmg debug

.PHONY: print-values
print-values:
	@printf '%s\n' $(VALUES)

podman-buildall: $(foreach v, $(VALUES), podman-build-$(v))

podman-build-%:
	@echo "Platform: $(PLATFORM)"
	$(MAKE) clean-image VAR=$*
	$(MAKE) build-image VAR=$*

podman-pushall: $(foreach v, $(VALUES), podman-push-$(v))

ifdef GITHUB_ACTIONS
podman-push-%:
	podman push ${IMG_PREFIX}:$* docker://${IMG_PREFIX}:$*
else
podman-push-%:
	podman manifest push ${IMG_PREFIX}:$* docker://${IMG_PREFIX}:$*
endif

podman-saveall: $(foreach v, $(VALUES), podman-save-$(v))

ifdef GITHUB_ACTIONS
podman-save-%:
	mkdir -p $(SAVE_DIR)
	podman save -o $(SAVE_DIR)/$*.tar ${IMG_PREFIX}:$*
else
podman-save-%:
	mkdir -p $(SAVE_DIR)
	podman save -m -o $(SAVE_DIR)/$*.tar ${IMG_PREFIX}:$*
endif

podman-build-and-pushall: $(foreach v, $(VALUES), podman-build-and-push-$(v))

podman-build-and-push-%:
	$(MAKE) podman-clean-$*
	$(MAKE) podman-build-$*
	$(MAKE) podman-push-$*

podman-build-and-saveall: $(foreach v, $(VALUES), podman-build-and-save-$(v))

podman-build-and-save-%:
	$(MAKE) podman-clean-$*
	$(MAKE) podman-build-$*
	$(MAKE) podman-save-$*

ifdef GITHUB_ACTIONS
build-image: stage-build-context
	podman build $(CACHE_FLAG) --network host --platform $(PLATFORM) $(PODMAN_BUILD_ARGS) -t ${IMG_PREFIX}:$(VAR) -f $(PTP_TOOLS_DIR)/Dockerfile.$(VAR) $(OPERATOR_ROOT)
else
build-image: stage-build-context
	podman manifest create ${IMG_PREFIX}:$(VAR)
	podman build $(CACHE_FLAG) --network host --platform $(PLATFORM) $(PODMAN_BUILD_ARGS) -f $(PTP_TOOLS_DIR)/Dockerfile.$(VAR) --manifest ${IMG_PREFIX}:$(VAR) $(OPERATOR_ROOT)
endif

ifdef GITHUB_ACTIONS
clean-image:
	podman rmi ${IMG_PREFIX}:$(VAR) || true

podman-clean-%:
	podman rmi ${IMG_PREFIX}:$* || true
else
clean-image:
	podman manifest rm ${IMG_PREFIX}:$(VAR) || true

podman-clean-%:
	podman manifest rm ${IMG_PREFIX}:$* || true
endif

podman-cleanall: $(foreach v, $(VALUES), podman-clean-$(v))

.PHONY: podman-buildall podman-pushall podman-saveall podman-cleanall
.PHONY: podman-build-and-pushall podman-build-and-saveall
.PHONY: build-image clean-image deploy-all stage-build-context print-values

# Dockerfiles COPY ptp-tools/extra and scripts/ptp-vrt relative to OPERATOR_ROOT.
stage-build-context:
	mkdir -p $(OPERATOR_ROOT)/ptp-tools/extra $(OPERATOR_ROOT)/scripts/ptp-vrt
	@if [ -d $(PTP_TOOLS_DIR)/extra ]; then cp -a $(PTP_TOOLS_DIR)/extra/. $(OPERATOR_ROOT)/ptp-tools/extra/; fi
	@if [ -d $(PTP_TOOLS_DIR)/../scripts/ptp-vrt ]; then cp -a $(PTP_TOOLS_DIR)/../scripts/ptp-vrt/. $(OPERATOR_ROOT)/scripts/ptp-vrt/; fi

deploy-all:
	cp $(OPERATOR_ROOT)/config/manager/env.yaml $(OPERATOR_ROOT)/config/manager/env.yaml.bak
	cp $(OPERATOR_ROOT)/config/manager/kustomization.yaml $(OPERATOR_ROOT)/config/manager/kustomization.yaml.bak
	OPERATOR_ROOT=$(OPERATOR_ROOT) ./scripts/customize-env.sh ${IMG_PREFIX} $(OPERATOR_ROOT)/config/manager
	cd $(OPERATOR_ROOT)/config/manager && $(KUSTOMIZE) edit set image controller=${IMG_PREFIX}:ptpop
	$(KUSTOMIZE) build $(OPERATOR_ROOT)/config/default | kubectl apply -f - ; \
		mv -f $(OPERATOR_ROOT)/config/manager/env.yaml.bak $(OPERATOR_ROOT)/config/manager/env.yaml ; \
		mv -f $(OPERATOR_ROOT)/config/manager/kustomization.yaml.bak $(OPERATOR_ROOT)/config/manager/kustomization.yaml
	$(KUSTOMIZE) build $(OPERATOR_ROOT)/config/custom | kubectl apply -f -
	# Operator creates default asynchronously; ensure it exists before patch.
	kubectl apply -n openshift-ptp -f $(OPERATOR_ROOT)/config/samples/ptp_v1_ptpoperatorconfig.yaml
	kubectl patch ptpoperatorconfig default -nopenshift-ptp --type=merge --patch '{"spec": {"ptpEventConfig": {"enableEventPublisher": true, "transportHost": "http://ptp-event-publisher-service-NODE_NAME.openshift-ptp.svc.cluster.local:9043", "storageType": "local-sc"}, "daemonNodeSelector": {"node-role.kubernetes.io/worker": ""}}}'
