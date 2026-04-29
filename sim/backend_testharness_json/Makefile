KANATA ?= 0
INPUT ?= program.json
BUILD_DIR ?= build
MACHINE_WIDTH ?= 4

ifeq ($(KANATA),1)
	CMAKE_EXTRA_ARGS := -DENABLE_KANATA=ON -DKANATA_LOG_NAME=backend_testharness_json
else
	CMAKE_EXTRA_ARGS :=
endif

.PHONY: all build run clean

all: build

build:
	mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && cmake .. $(CMAKE_EXTRA_ARGS) -DMACHINE_WIDTH=$(MACHINE_WIDTH) && $(MAKE)

run: build
	./$(BUILD_DIR)/sim_backend_testharness_json --input $(INPUT)

clean:
	rm -rf $(BUILD_DIR)
