SHELL := /bin/zsh

.PHONY: test build clean

TEST_SCRIPT ?= ./tests/run.sh


test:
	@$(TEST_SCRIPT)

build:
	@$(TEST_SCRIPT) --suite build

clean:
	@rm -rf build dist

.PHONY: test-pages
PYTHON ?= python3
test-pages:
	@$(PYTHON) -m unittest discover -s tests -p test_pages_proxy.py -v
