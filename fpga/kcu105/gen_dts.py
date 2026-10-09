#!/usr/bin/env python3
"""Describe the generated O3 SoC for OpenSBI/Linux using its actual CSR map."""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "litex_wrapper"))
from o3.platform import load_platform, platform_regions, irq_map


def render(csr, bootargs):
    config = load_platform()
    regions = platform_regions(config=config)
    irq = irq_map(config)
    def base(name):
        value = csr["csr_bases"][name]
        return int(value, 0) if isinstance(value, str) else value
    def reg(name):
        r = regions[name]
        return f"<0 0x{r['origin']:x} 0 0x{r['size']:x}>"
    def register(name):
        value = csr["csr_registers"][name]["addr"]
        return int(value, 0) if isinstance(value, str) else value
    sd = [(register(name), size) for name, size in (
        ("sdcard_phy_card_detect", 0x1c), ("sdcard_core_cmd_argument", 0x2c),
        ("sdcard_block2mem_dma_base", 0x20), ("sdcard_mem2block_dma_base", 0x20),
        ("sdcard_ev_status", 0x0c))]
    sd_regs = ", ".join(f"<0 0x{addr:x} 0 0x{size:x}>" for addr, size in sd)
    # These register sizes are the LiteSDCard v1 binding. Verify actual CSRs
    # occupy the described ranges, rather than silently describing another IP.
    registers = csr["csr_registers"]
    for prefix, (addr, size) in zip(("sdcard_phy_", "sdcard_core_", "sdcard_block2mem_", "sdcard_mem2block_", "sdcard_ev_"), sd):
        for name, item in registers.items():
            if name.startswith(prefix) and not addr <= register(name) < addr + size:
                raise ValueError(f"LiteSDCard binding changed: {name}")
    uart = base("uart")
    bootargs = json.dumps(bootargs)
    return f"""/dts-v1/;
/ {{
    #address-cells = <2>; #size-cells = <2>;
    compatible = "cislc,o3-litex", "litex,soc";
    model = "CISLC O3 single-hart KCU105 DDR4 SD";
    aliases {{ serial0 = &uart0; mmc0 = &sdcard; }};
    chosen {{ stdout-path = "serial0"; bootargs = {bootargs}; }};
    cpus {{
        #address-cells = <1>; #size-cells = <0>;
        timebase-frequency = <{config['machineTimer']['mtimeFrequencyHz']}>;
        cpu0: cpu@0 {{
            device_type = "cpu"; reg = <0>; compatible = "riscv";
            status = "okay"; clock-frequency = <{config['systemClockHz']}>;
            riscv,isa = "rv64imafdc_zicsr_zifencei_zihpm_sstc_sscofpmf";
            mmu-type = "riscv,sv39";
            cpu0_intc: interrupt-controller {{
                #address-cells = <0>; #interrupt-cells = <1>;
                interrupt-controller; compatible = "riscv,cpu-intc";
            }};
        }};
    }};
    memory@80000000 {{ device_type = "memory"; reg = {reg('main_ram')}; }};
    reserved-memory {{
        #address-cells = <2>; #size-cells = <2>; ranges;
        sd-bios-scratch@fffff000 {{ reg = <0 {config['sdcard']['biosScratchOrigin']} 0 {config['sdcard']['biosScratchSize']}>; no-map; }};
    }};
    sys_clk: clock {{ compatible = "fixed-clock"; #clock-cells = <0>; clock-frequency = <{config['systemClockHz']}>; }};
    vreg_mmc: regulator {{ compatible = "regulator-fixed"; regulator-name = "sd-3v3";
        regulator-min-microvolt = <3300000>; regulator-max-microvolt = <3300000>; regulator-always-on; }};
    soc {{
        #address-cells = <2>; #size-cells = <2>; compatible = "simple-bus"; ranges;
        timer@2000000 {{ compatible = "riscv,clint0"; reg = {reg('machine_timer')};
            interrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>; }};
        plic: interrupt-controller@c000000 {{
            #address-cells = <0>; #interrupt-cells = <1>; interrupt-controller;
            compatible = "riscv,plic0"; reg = {reg('plic')};
            riscv,ndev = <{config['externalInterrupts']['numSources']}>; riscv,max-priority = <7>;
            interrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>;
        }};
        uart0: serial@{uart:x} {{ compatible = "litex,liteuart"; reg = <0 0x{uart:x} 0 0x100>;
            interrupt-parent = <&plic>; interrupts = <{irq['uart']}>; status = "okay"; }};
        sdcard: mmc@{sd[0][0]:x} {{
            compatible = "litex,mmc"; reg = {sd_regs};
            reg-names = "phy", "core", "reader", "writer", "irq";
            clocks = <&sys_clk>; vmmc-supply = <&vreg_mmc>;
            interrupt-parent = <&plic>; interrupts = <{irq['sdcard']}>;
            bus-width = <4>; max-frequency = <5000000>; dma-coherent;
            status = "okay";
        }};
    }};
}};
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csr-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bootargs", default="earlycon=liteuart,0x12001000 console=liteuart root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw")
    args = parser.parse_args()
    args.output.write_text(render(json.loads(args.csr_json.read_text()), args.bootargs))


if __name__ == "__main__":
    main()
