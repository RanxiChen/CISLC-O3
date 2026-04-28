ROOT_DIR := ../..
RTL_DIR := $(ROOT_DIR)/rtl
SIM_DIR := .
OBJ_DIR := $(SIM_DIR)/obj_dir

VERILATOR ?= verilator
TOP := ICache
CPP_TB := $(SIM_DIR)/tb_icache.cpp

RTL_SRCS := \
	$(RTL_DIR)/common/o3_sram.sv \
	$(RTL_DIR)/common/lfsr.sv \
	$(RTL_DIR)/frontend/icache.sv

VERILATOR_DEFINES := \
	-DO3_SIM \
	-DO3_ICACHE_DEBUG \
	-DO3_ICACHE_WAY0_VALID

VERILATOR_FLAGS := \
	--cc \
	--exe \
	--build \
	--top-module $(TOP) \
	--sv \
	-Wall \
	-Wno-fatal \
	$(VERILATOR_DEFINES) \
	-Mdir $(OBJ_DIR)

RUN_BIN := $(OBJ_DIR)/V$(TOP)

.PHONY: all run clean

all: $(RUN_BIN)

$(RUN_BIN): $(RTL_SRCS) $(CPP_TB)
	cd $(SIM_DIR) && $(VERILATOR) $(VERILATOR_FLAGS) $(CPP_TB) $(RTL_SRCS)

run: $(RUN_BIN)
	cd $(SIM_DIR) && ./obj_dir/V$(TOP)

clean:
	rm -rf $(OBJ_DIR)
