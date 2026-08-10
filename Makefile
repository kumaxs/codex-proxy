SHELL := /bin/zsh

.PHONY: test build clean

TEST_SCRIPT ?= ./tests/run.sh


test:
	@$(TEST_SCRIPT)

build:
	@$(TEST_SCRIPT) --suite build

clean:
	@rm -rf build dist
