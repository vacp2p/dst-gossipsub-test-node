# Copyright (c) 2022 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.
BUILD_SYSTEM_DIR := vendor/nimbus-build-system

# we don't want an error here, so we can handle things later, in the ".DEFAULT" target
-include $(BUILD_SYSTEM_DIR)/makefiles/variables.mk

ifeq ($(NIM_PARAMS),)
# "variables.mk" was not included, so we update the submodules.
GIT_SUBMODULE_UPDATE := git submodule update --init --recursive
.DEFAULT:
	+@ echo -e "Git submodules not found. Running '$(GIT_SUBMODULE_UPDATE)'.\n"; \
		$(GIT_SUBMODULE_UPDATE); \
		echo
# Now that the included *.mk files appeared, and are newer than this file, Make will restart itself:
# https://www.gnu.org/software/make/manual/make.html#Remaking-Makefiles
#
# After restarting, it will execute its original goal, so we don't have to start a child Make here
# with "$(MAKE) $(MAKECMDGOALS)". Isn't hidden control flow great?

else # "variables.mk" was included. Business as usual until the end of this file.

# must be included after the default target
-include $(BUILD_SYSTEM_DIR)/makefiles/targets.mk

.PHONY: deps

deps: | deps-common

dstnode: | build deps
	echo -e $(BUILD_MSG) "build/$@" && \
	    $(ENV_SCRIPT) nim dstnode $(NIM_PARAMS)

clean: | clean-common
	rm -rf build/dstnode

#####################
## Container image ##
#####################
# -d:insecure - Necessary to enable Prometheus HTTP endpoint for metrics
# -d:chronicles_colors:none - Necessary to disable colors in logs for Docker
DOCKER_IMAGE_NIMFLAGS := -d:chronicles_colors:none -d:insecure --threads:on -d:metrics -d:libp2p_network_protocols_metrics -d:release
# build a docker image
docker-image: MAKE_TARGET ?= dstnode
docker-image: DOCKER_IMAGE_TAG ?= asoutullo/dst-test-node:v0.2
docker-image:
	docker build \
		--build-arg="MAKE_TARGET=$(MAKE_TARGET)" \
		--build-arg="NIMFLAGS=$(DOCKER_IMAGE_NIMFLAGS)" \
		--target prod \
		--tag $(DOCKER_IMAGE_TAG) .

docker-push:
	docker push $(DOCKER_IMAGE_TAG)

endif