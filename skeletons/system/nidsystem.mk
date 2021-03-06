# Common Makefile for NSO in Docker system standard form.
#
# A repository that follows the standard form for a NID (NSO in Docker) system
# repository contains one or more NSO packages in the `/packages` directory,
# which are built and assembled into a Docker image of those packages on top of
# a base NSO image.
#
# There are two kind of environments that can be started:
# - testenv
# - devenv
#
# They are conceptually very similar and the devenv is started by reusing
# testenv-start target and passing extra arguments. With testenv, a Docker image
# is assumed to have been already built that contains the primary package
# artifacts and any necessary test-packages. Changing any package or
# test-package involves rebuilding the Docker image and restarting the entire
# testenv. In a typical development cycle, we want to have a fast REPL cycle,
# i.e. the typical cycle a developer goes through when writing code. Having to
# wait multiple minutes between writing code and being able to test it is not
# conducive to efficient development, thus the devenv. A devenv instead starts
# the testenv as normal but places NSO package in a Docker volume. As part of
# the REPL loop it is now possible for a developer to copy their updates source
# code onto the Docker volume, recompile the code and then reload it in NSO.
# This drastically reduces the length of the REPL loop and thus improves the
# environment for the developer.
#
# testenvs are used for CI or local testing. devenv is used exclusively for
# local development.


# Determine our project name, either from CI_PROJECT_NAME which is normally set
# by GitLab CI or by looking at the name of our directory (that we are in).
ifneq ($(CI_PROJECT_NAME),)
PROJECT_NAME=$(CI_PROJECT_NAME)
else
PROJECT_NAME:=$(shell basename $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST)))))
endif

include nidcommon.mk

all:
	$(MAKE) build
	$(MAKE) test

test:
	$(MAKE) testenv-start
	$(MAKE) testenv-test
	$(MAKE) testenv-stop


Dockerfile: Dockerfile.in $(wildcard includes/*)
	@echo "-- Generating Dockerfile"
# Expand variables before injecting them into the Dockerfile as otherwise we
# would have to pass all the variables as build-args which makes this much
# harder to do in a generic manner. This works across GNU and BSD awk.
	cp Dockerfile.in Dockerfile
	for DEP_NAME in $$(ls includes/* | $(XARGS) -n1 basename); do export DEP_URL=$$(awk '{ print "echo", $$0 }' includes/$${DEP_NAME} | $(SHELL) -); awk "/DEP_END/ { print \"FROM $${DEP_URL} AS $${DEP_NAME}\" }; /DEP_INC_END/ { print \"COPY --from $${DEP_NAME} /var/opt/ncs/packages/ /var/opt/ncs/packages/\" }; 1" Dockerfile > Dockerfile.tmp; mv Dockerfile.tmp Dockerfile; done

build: check-nid-available Dockerfile
	docker build --target nso -t $(IMAGE_PATH)$(PROJECT_NAME)/nso:$(DOCKER_TAG) --build-arg NSO_IMAGE_PATH=$(NSO_IMAGE_PATH) --build-arg NSO_VERSION=$(NSO_VERSION) .

push:
	docker push $(IMAGE_PATH)$(PROJECT_NAME)/nso:$(DOCKER_TAG)

tag-release:
	docker tag $(IMAGE_PATH)$(PROJECT_NAME)/nso:$(DOCKER_TAG) $(IMAGE_PATH)$(PROJECT_NAME)/nso:$(NSO_VERSION)

push-release:
	docker push $(IMAGE_PATH)$(PROJECT_NAME)/nso:$(NSO_VERSION)


# Development environment targets

devenv-shell:
	docker run -it -v $$(pwd):/src $(NSO_IMAGE_PATH)cisco-nso-dev:$(NSO_VERSION)

devenv-build:
	docker run -it --rm -v $(PWD):/src -v $(CNT_PREFIX)-packages:/dst $(NSO_IMAGE_PATH)cisco-nso-dev:$(NSO_VERSION) bash -lc 'cp -a /src/packages/* /dst/; cp -av /src/test-packages/* /dst/; for PKG in $$(ls /src/packages /src/test-packages); do make -C /dst/$${PKG}/src; done'
	$(MAKE) testenv-runcmdJ CMD="request packages reload"
	$(MAKE) testenv-runcmdJ CMD="show packages"

devenv-clean:
	docker run -it --rm -v $(PWD):/src -v $(CNT_PREFIX)-packages:/dst $(NSO_IMAGE_PATH)cisco-nso-dev:$(NSO_VERSION) bash -lc 'ls /dst/ | $(XARGS) rm -rf'

devenv-start:
	docker volume create $(CNT_PREFIX)-packages
	$(MAKE) NSO_EXTRA_ARGS="$(NSO_EXTRA_ARGS) -v $(CNT_PREFIX)-packages:/var/opt/ncs/packages" testenv-start


# Test environment targets

testenv-start:
	-docker network create $(CNT_PREFIX)
	docker run -td --name $(CNT_PREFIX)-nso $(DOCKER_ARGS) -e ADMIN_PASSWORD=NsoDocker1337 $${NSO_EXTRA_ARGS} $(IMAGE_PATH)$(PROJECT_NAME)/nso:$(DOCKER_TAG)
	$(MAKE) testenv-start-extra
	docker exec -t $(CNT_PREFIX)-nso bash -lc 'ncs --wait-started 600'
	$(MAKE) testenv-runcmdJ CMD="show packages"

testenv-stop:
	docker ps -aq --filter label=$(CNT_PREFIX) | $(XARGS) docker rm -f
	-docker network rm $(CNT_PREFIX)
	-docker volume rm $(CNT_PREFIX)-packages

testenv-shell:
	docker exec -it $(CNT_PREFIX)-nso bash -l

testenv-cli:
	docker exec -it $(CNT_PREFIX)-nso bash -lc 'ncs_cli -u admin'

testenv-runcmdC testenv-runcmdJ:
	@if [ -z "$(CMD)" ]; then echo "CMD variable must be set"; false; fi
	docker exec -t $(CNT_PREFIX)-nso$(NSO) bash -lc 'echo -e "$(CMD)" | ncs_cli -$(subst testenv-runcmd,,$@)u admin'


.PHONY: all test build push tag-release push-release devenv-shell devenv-build devenv-start testenv-start testenv-test testenv-stop
