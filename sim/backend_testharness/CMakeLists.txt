cmake_minimum_required(VERSION 4.0)
project(backend_testharness)

set(CMAKE_CXX_STANDARD 20)
get_filename_component(
        PROJ_ROOT_DIR
        ${CMAKE_SOURCE_DIR}/../../
        REALPATH
)

set(TB_SOURCE ${PROJ_ROOT_DIR}/tb/backend_testharness.sv)
set(RTL_SOURCES
    ${PROJ_ROOT_DIR}/rtl/common/o3_pkg.sv
    ${PROJ_ROOT_DIR}/rtl/backend/decoder.sv
    ${PROJ_ROOT_DIR}/rtl/backend/free_list.sv
    ${PROJ_ROOT_DIR}/rtl/backend/rename_map_table.sv
    ${PROJ_ROOT_DIR}/rtl/backend/uop_queue.sv
    ${PROJ_ROOT_DIR}/rtl/backend/rob.sv
    ${PROJ_ROOT_DIR}/rtl/backend/backend.sv
)

find_package(verilator HINTS $ENV{VERILATOR_ROOT})

add_executable(sim_backend_testharness
    main.cpp
    backend_instruction_stream.cpp
    dpi_compat_stubs.cpp
)

verilate(sim_backend_testharness
    TOP_MODULE backend_testharness
    PREFIX Vbackend_testharness
    SOURCES ${RTL_SOURCES} ${TB_SOURCE}
    VERILATOR_ARGS
        -DO3_SIM
        -I${PROJ_ROOT_DIR}/tb
    TRACE
)
