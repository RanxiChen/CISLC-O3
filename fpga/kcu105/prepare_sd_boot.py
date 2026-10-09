#!/usr/bin/env python3
"""Package supplied O3 firmware/kernel/DTB into a directory for a FAT partition.

Never opens a block device. Firmware/Linux compilation and board tests are
separate stages. fw_jump must target 0x80200000; handoff sets a0/a1 for OpenSBI.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--opensbi", type=Path, required=True)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--dtb", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cross-prefix", default="riscv64-unknown-elf-")
    args = parser.parse_args()
    files = [(args.opensbi, "fw_jump.bin", 0x80000000, 0x80080000),
             (args.dtb, "o3-kcu105.dtb", 0x80100000, 0x80200000),
             (args.kernel, "Image", 0x80200000, 0xfffff000)]
    for source, name, addr, limit in files:
        if not source.is_file() or not 0 < source.stat().st_size <= limit - addr:
            raise SystemExit(f"{name}: missing, empty or overlaps reserved boot memory")
    if args.dtb.read_bytes()[:4] != bytes.fromhex("d00dfeed"):
        raise SystemExit("invalid DTB magic")
    args.output.mkdir(parents=True, exist_ok=False)
    for source, name, _, _ in files:
        shutil.copyfile(source, args.output / name)
    source = Path(__file__).resolve().parent
    elf = args.output / "handoff.elf"
    subprocess.run([args.cross_prefix + "gcc", "-march=rv64im_zicsr_zifencei", "-mabi=lp64",
        "-nostdlib", "-nostartfiles", "-Wl,--no-relax", "-T", str(source / "handoff.ld"),
        str(source / "handoff.S"), "-o", str(elf)], check=True)
    subprocess.run([args.cross_prefix + "objcopy", "-O", "binary", str(elf),
                    str(args.output / "handoff.bin")], check=True)
    boot = {name: hex(addr) for _, name, addr, _ in files}
    boot.update({"handoff.bin": "0x80080000", "addr": "0x80080000"})
    (args.output / "boot.json").write_text(json.dumps(boot, indent=2) + "\n")
    manifest = {name: dict(bytes=(args.output / name).stat().st_size,
                          sha256=hashlib.sha256((args.output / name).read_bytes()).hexdigest())
                for name in boot if name != "addr"}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
