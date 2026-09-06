ACT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(ACT_DIR)/../..)
UPSTREAM_DIR ?= $(ACT_DIR)/.upstream
WORK_DIR ?= $(ACT_DIR)/.work
OUT_DIR ?= $(ACT_DIR)/out
ELF_DIR ?= $(WORK_DIR)/cislc-o3-rv64i/elfs
EXTENSIONS ?= I
MAX_CYCLES ?= 1000000
MATCH ?= *.elf

.PHONY: fetch build sim run clean-output

fetch:
	ACT4_UPSTREAM_DIR=$(UPSTREAM_DIR) ./scripts/fetch_act4.sh

build:
	ACT4_UPSTREAM_DIR=$(UPSTREAM_DIR) ACT4_WORK_DIR=$(WORK_DIR) \
		ACT4_EXTENSIONS=$(EXTENSIONS) ./scripts/build_tests.sh

sim:
	$(MAKE) -C $(REPO_ROOT)/sim/o3 build

run:
	python3 ./scripts/run_suite.py $(ELF_DIR) \
		--sim $(REPO_ROOT)/sim/o3/build/Vo3_tandem_top \
		--output-dir $(OUT_DIR) --max-cycles $(MAX_CYCLES) \
		--match '$(MATCH)' --keep-going

clean-output:
	rm -rf $(OUT_DIR)
