"""O3 board diagnostics using Vivado ILA; observes without modifying traffic."""
import json
from pathlib import Path
from migen import Cat, ClockSignal, Instance, Module


class O3DebugILA(Module):
    def __init__(self, cpu, platform):
        signals = [cpu.retire_valid, cpu.retire_pc, cpu.retire_inst, cpu.retired_count,
                   Cat(cpu.fatal, cpu.inclusion_err, cpu.dma_busy, cpu.msip, cpu.mtip, cpu.meip, cpu.seip),
                   Cat(cpu.memory_bus.ar.valid, cpu.memory_bus.ar.ready, cpu.memory_bus.ar.addr,
                       cpu.memory_bus.aw.valid, cpu.memory_bus.aw.ready, cpu.memory_bus.aw.addr,
                       cpu.memory_bus.r.valid, cpu.memory_bus.r.ready, cpu.memory_bus.r.last,
                       cpu.memory_bus.w.valid, cpu.memory_bus.w.ready, cpu.memory_bus.w.last,
                       cpu.memory_bus.b.valid, cpu.memory_bus.b.ready)]
        names = ["retire_valid", "retire_pc", "retire_inst", "retired_count", "status", "memory_axi"]
        self.probes = [dict(probe=i, name=name, width=len(sig)) for i, (name, sig) in enumerate(zip(names, signals))]
        commands = platform.toolchain.pre_synthesis_commands
        commands.append("create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name o3_ila")
        settings = ["CONFIG.C_DATA_DEPTH 2048", f"CONFIG.C_NUM_OF_PROBES {len(signals)}"]
        settings += [f"CONFIG.C_PROBE{i}_WIDTH {len(sig)}" for i, sig in enumerate(signals)]
        commands.append("set_property -dict [list " + " ".join(settings) + "] [get_ips o3_ila]")
        commands.append("generate_target all [get_ips o3_ila]")
        self.specials += Instance("o3_ila", i_clk=ClockSignal("sys"),
                                 **{f"i_probe{i}": sig for i, sig in enumerate(signals)})

    def write_probe_map(self, path):
        Path(path).write_text(json.dumps(self.probes, indent=2) + "\n")
