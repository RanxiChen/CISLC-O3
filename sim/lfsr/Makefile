VERILATOR ?= verilator
SIM_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
ROOT_DIR := $(abspath $(SIM_DIR)/../..)
RTL := $(ROOT_DIR)/rtl/common/lfsr.sv
TOP := lfsr
OBJ_DIR := $(SIM_DIR)/obj_dir
BIN := $(OBJ_DIR)/V$(TOP)

.PHONY: all run clean

all: $(BIN)

$(BIN): $(RTL) $(SIM_DIR)/main.cpp
	$(VERILATOR) --cc --exe --build \
		--top-module $(TOP) \
		-Mdir $(OBJ_DIR) \
		$(RTL) $(SIM_DIR)/main.cpp

run: $(BIN)
	$(BIN) $(RUN_ARGS)

clean:
	rm -rf $(OBJ_DIR)
