cmake_minimum_required(VERSION 4.0)
project(frontend_testharness)

set(CMAKE_CXX_STANDARD 20)
get_filename_component(
        PROJ_ROOT_DIR
        ${CMAKE_SOURCE_DIR}/../../
        REALPATH
)
set(RTL_DIR ${PROJ_ROOT_DIR}/rtl/)

## 收集RTL目录下所有的.sv和.v文件
file(GLOB_RECURSE RTL_SOURCES
    ${RTL_DIR}/*.sv
    ${RTL_DIR}/*.v
)

set(TB_SOURCE ${PROJ_ROOT_DIR}/tb/frontend_testharness.sv)

## verilator
find_package(verilator HINTS $ENV{VERILATOR_ROOT})

## 先创建可执行目标
add_executable(sim_frontend_testharness
    main.cpp
    dpi_logger.cpp       # 使用 C++ 版本的 DPI 函数
    riscv_exec_model.cpp # RISC-V 执行模型（分支解码和执行）
    # dpi_logger.c       # 或使用纯 C 版本（取消注释这行，注释上面那行）
)

## 然后对已存在的目标进行 verilate 配置
verilate(sim_frontend_testharness
        TOP_MODULE frontend_testharness
        PREFIX Vfrontend_testharness
        SOURCES ${RTL_SOURCES} ${TB_SOURCE}
        VERILATOR_ARGS -DO3_SIM
        TRACE
)

## 如果inst.hex放在当前目录，编译后拷贝到可执行目录
if (EXISTS ${CMAKE_SOURCE_DIR}/inst.hex)
    add_custom_command(TARGET sim_frontend_testharness POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_SOURCE_DIR}/inst.hex
        $<TARGET_FILE_DIR:sim_frontend_testharness>/inst.hex
    )
endif()
