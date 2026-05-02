cmake_minimum_required(VERSION 3.22)
project(backend_testharness_json)

set(CMAKE_CXX_STANDARD 20)
get_filename_component(
        PROJ_ROOT_DIR
        ${CMAKE_SOURCE_DIR}/../../
        REALPATH
)

set(TB_SOURCE ${PROJ_ROOT_DIR}/tb/backend_testharness_json.sv)
set(RTL_SOURCES
    ${PROJ_ROOT_DIR}/rtl/common/o3_pkg.sv
    ${PROJ_ROOT_DIR}/rtl/backend/decoder.sv
    ${PROJ_ROOT_DIR}/rtl/backend/free_list.sv
    ${PROJ_ROOT_DIR}/rtl/backend/rename_map_table.sv
    ${PROJ_ROOT_DIR}/rtl/backend/uop_queue.sv
    ${PROJ_ROOT_DIR}/rtl/backend/rob.sv
    ${PROJ_ROOT_DIR}/rtl/backend/issue_queue.sv
    ${PROJ_ROOT_DIR}/rtl/backend/physical_regfile.sv
    ${PROJ_ROOT_DIR}/rtl/backend/int_execute_unit.sv
    ${PROJ_ROOT_DIR}/rtl/backend/backend.sv
)

set(VERILATOR_EXTRA_ARGS "" CACHE STRING "Extra verilator args")
set(MACHINE_WIDTH 4 CACHE STRING "Backend machine width")
option(ENABLE_KANATA "Enable Kanata log output" OFF)
set(KANATA_LOG_NAME "backend_testharness_json" CACHE STRING "Kanata log base name")

if (VERILATOR_EXTRA_ARGS)
    separate_arguments(VERILATOR_EXTRA_ARGS)
endif()

set(VERILATOR_KANATA_ARGS "")
if (ENABLE_KANATA)
    list(APPEND VERILATOR_KANATA_ARGS
        -DO3_SIM_KANATA
        -DO3_SIM_KANATA_LOG_NAME=\"${KANATA_LOG_NAME}\"
    )
endif()

find_package(verilator HINTS $ENV{VERILATOR_ROOT})

add_executable(sim_backend_testharness_json
    main.cpp
    backend_instruction_stream.cpp
    dpi_compat_stubs.cpp
)

target_compile_definitions(sim_backend_testharness_json PRIVATE MACHINE_WIDTH=${MACHINE_WIDTH})

verilate(sim_backend_testharness_json
    TOP_MODULE backend_testharness_json
    PREFIX Vbackend_testharness_json
    SOURCES ${RTL_SOURCES} ${TB_SOURCE}
    VERILATOR_ARGS
        -DO3_SIM
        -I${PROJ_ROOT_DIR}/tb
        -GMACHINE_WIDTH=${MACHINE_WIDTH}
        ${VERILATOR_KANATA_ARGS}
        ${VERILATOR_EXTRA_ARGS}
    TRACE
)
