#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
act_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
upstream_dir=${ACT4_UPSTREAM_DIR:-$act_dir/.upstream}
work_dir=${ACT4_WORK_DIR:-$act_dir/.work}
extensions=${ACT4_EXTENSIONS:-I}
config_file=$act_dir/config/cislc-o3-rv64i/test_config.yaml
toolchain_root=${ACT4_TOOLCHAIN_ROOT:-/home/chen/opt/act4/gcc-2026.07.15}
sail_root=${ACT4_SAIL_ROOT:-/home/chen/opt/act4/sail-0.13.1}
mise_root=${ACT4_MISE_ROOT:-/home/chen/.local/bin}

export PATH="$toolchain_root/bin:$sail_root/bin:$mise_root:$PATH"

test -d "$upstream_dir/.git" || {
    echo "ACT4 checkout missing; run make fetch first" >&2
    exit 2
}
command -v mise >/dev/null || { echo "missing mise" >&2; exit 2; }
command -v riscv64-unknown-elf-gcc >/dev/null || {
    echo "missing riscv64-unknown-elf-gcc" >&2
    exit 2
}
gcc_version=$(riscv64-unknown-elf-gcc -dumpfullversion)
gcc_major=${gcc_version%%.*}
case "$gcc_major" in
    ''|*[!0-9]*) echo "cannot parse RISC-V GCC version: $gcc_version" >&2; exit 2 ;;
esac
test "$gcc_major" -ge 15 || {
    echo "RISC-V GCC $gcc_version is too old; ACT4 requires GCC 15 or newer" >&2
    exit 2
}
command -v sail_riscv_sim >/dev/null || { echo "missing sail_riscv_sim" >&2; exit 2; }
case "$(sail_riscv_sim --version 2>&1)" in
    *0.13.1*) ;;
    *) echo "pinned ACT4 requires Sail 0.13.1" >&2; exit 2 ;;
esac

make -C "$upstream_dir" CONFIG_FILES="$config_file" \
    WORKDIR="$work_dir" EXTENSIONS="$extensions"

echo "ACT4_BUILD_DONE extensions=$extensions work=$work_dir"
