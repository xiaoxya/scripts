SHELL := /usr/bin/env bash

.PHONY: test lint

test: lint
	@bash tests/smoke.sh

lint:
	@bash -n bin/*.sh lib/*.sh tests/*.sh
