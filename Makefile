# $Id$
.PHONY: clean all

ROOT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
CONTAINER_BASE_DIR := /tmp/func
CONTAINER_TAG=5.30

all: clean cpanfile
ifndef CONTAINER_TAG
	@echo '[ERROR] $$CONTAINER_TAG must be specified'
	@echo 'usage: make build CONTAINER_TAG=x.x'
	exit 255
endif
	for x in *pl; do echo $$x; perl -cw $$x && /Users/leeym/src/sh/perltidy.sh $$x; done
	git status --porcelain | grep ^\? | awk '{print $$NF}' | xargs git add
	-git commit -am "`git status --porcelain | awk '{print $$NF}' | awk -F/ '{print $$1}' | sort -u | xargs`"
	git push

clean:
	rm -rf \
		local \
		cpanfile \
		cpanfile.snapshot \
		func.zip

cpanfile:
	cat *.pl | grep "^use [A-Z]" | awk '{print $$2}' | sed 's/;//' | sort -u | sed "s/^/requires '/;s/$$/', '0';/" > cpanfile

