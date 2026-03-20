cmake_minimum_required(VERSION 4.0)
project(physical_regfile_testharness)

set(CMAKE_CXX_STANDARD 20)
get_filename_component(
        PROJ_ROOT_DIR
        ${CMAKE_SOURCE_DIR}/../../
        REALPATH
)

set(TB_SOURCE ${PROJ_ROOT_DIR}/tb/physical_regfile_testharness.sv)
set(RTL_SOURCES
    ${PROJ_ROOT_DIR}/rtl/common/o3_pkg.sv
    ${PROJ_ROOT_DIR}/rtl/backend/physical_regfile.sv
)

find_package(verilator HINTS $ENV{VERILATOR_ROOT})

function(add_regfile_sim_target target_name read_ports write_ports entries data_width)
    add_executable(${target_name} main.cpp)
    target_compile_definitions(${target_name} PRIVATE
        NUM_READ_PORTS=${read_ports}
        NUM_WRITE_PORTS=${write_ports}
        NUM_ENTRIES=${entries}
        DATA_WIDTH=${data_width}
    )

    verilate(${target_name}
        TOP_MODULE physical_regfile_testharness
        PREFIX Vphysical_regfile_testharness
        SOURCES ${RTL_SOURCES} ${TB_SOURCE}
        VERILATOR_ARGS
            -DFPGA_TARGET
            -GNUM_READ_PORTS=${read_ports}
            -GNUM_WRITE_PORTS=${write_ports}
            -GNUM_ENTRIES=${entries}
            -GDATA_WIDTH=${data_width}
        TRACE
    )
endfunction()

add_regfile_sim_target(sim_physical_regfile_small 2 1 16 64)
add_regfile_sim_target(sim_physical_regfile_full 8 4 64 64)
