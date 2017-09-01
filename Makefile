.ONESHELL:
.PHONY: help test docker-build docker-publish rpm-publish
.DEFAULT_GOAL := help

SHELL := /bin/bash

NAME := logbus
VERSION := 0.5.14
MAINTAINER := foo@bar.com

DOCKER_REPO := docker.repo/
DOCKER_TAG := $(DOCKER_REPO)logbus

YUM_SERVER := yum.server
YUM_REPO := /opt/yum


help: ## show target summary
	@grep -E '^\S+:.* ## .+$$' $(MAKEFILE_LIST) | sed 's/##/#/' | while IFS='#' read spec help; do \
	  tgt=$${spec%%:*}; \
	  printf "\n%s: %s\n" "$$tgt" "$$help"; \
	  awk -F ': ' -v TGT="$$tgt" '$$1 == TGT && $$2 ~ "=" { print $$2 }' $(MAKEFILE_LIST) | \
	  while IFS='#' read var help; do \
	    printf "  %s  :%s\n" "$$var" "$$help"; \
	  done \
	done


node_modules: package.json ## install dependencies
	npm install

start: VERBOSITY=info# log level
start: CONF=config/test.yml# logbus config file
start: node_modules ## start logbus
	node bin/logbus.js -v $(VERBOSITY) $(CONF) -c


test: node_modules ## run automated tests
	diff -U2 test/dead-ends/out.txt <(./bin/logbus.js -c test/dead-ends/conf.yml)
	for dir in $$(ls -d test/* | grep -v dead-ends); do \
	  test -f $$dir/conf.yml && echo $$dir && ./bin/logbus.js $$dir/conf.yml && diff -U2 $$dir/expected.json <(jq -S --slurp 'from_entries' < $$dir/out.json); \
	done

docker-build: Dockerfile ## build docker image
	docker build -t $(DOCKER_TAG) .


docker-publish: ## publish docker image to repo
	docker push $(DOCKER_TAG)


# Experiment with other container runtimes:
#
# pkg/opt/logbus/rootfs: docker-build ## build rootfs
# 	test -d pkg/opt/logbus/rootfs || mkdir -p pkg/opt/logbus/rootfs
# 	cid=$$(docker run -i -d $(DOCKER_TAG) sh)
# 	docker export $$cid | tar x -C pkg/opt/logbus/rootfs
# 	docker rm -f $$cid


RELEASE := $(shell echo $$(( $$(rpm -qp --qf %{RELEASE} rpm 2>/dev/null) + 1)))
rpm: Makefile lib bin node_modules ## build rpm
	rsync -va package.json pkg/opt/logbus/package.json
	rsync -va --exclude test/ --exclude alasql/utils/ node_modules/ --delete-excluded pkg/opt/logbus/node_modules/
	rsync -va lib/ pkg/opt/logbus/lib/
	rsync -va bin/ pkg/opt/logbus/bin/
	cp node_modules/.bin/bunyan pkg/opt/logbus/bin/
	fpm --force --rpm-os linux -s dir -t rpm -C pkg --package rpm --name $(NAME) \
	  --version $(VERSION) --iteration $(RELEASE) \
	  --after-install post-install.sh \
	  --depends nodejs \
	  --vendor custrom --maintainer '<$(MAINTAINER)>' \
	  --rpm-summary 'Log shipper' --url https://github.com/skorpworks/logbus --rpm-changelog CHANGELOG


rpm-publish: rpm ## publish rpm to yum server
	scp rpm $(YUM_SERVER):$(YUM_REPO)/Packages/$(shell rpm -qp --qf %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm rpm)
	ssh $(YUM_SERVER) createrepo --update $(YUM_REPO)


shippers/%.rpm: VERSION=0.1# version
shippers/%.rpm: ## build shipper specific rpms
	mkdir -p build/etc/logbus/ build/etc/systemd/system
	rsync -vaL --delete shippers/$*/ build/etc/logbus/
	rsync -va shippers/logbus.service build/etc/systemd/system/logbus.service
	fpm --force --rpm-os linux -s dir -t rpm -C build --package $@ --name logbus-shipper-$* \
	  --version $(VERSION) \
	  --after-install shippers/post-install.sh \
	  --depends logbus \
	  --vendor custom --maintainer '<$(MAINTAINER)>' \
	  --rpm-summary 'Config for $* logbus shipper' --url https://github.com/skorpworks/logbus
