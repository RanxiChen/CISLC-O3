"""Passive O3 ILA probes and sticky watchdog; never drive bus handshakes."""
import json
from pathlib import Path
from migen import Cat, ClockSignal, If, Instance, Module, Signal


class O3Watchdog(Module):
    def __init__(self, cpu, threshold=10_000_000):
        if threshold < 2:
            raise ValueError("watchdog threshold must be at least two system cycles")
        self.hang = Signal()
        self.reasons = Signal(15)
        self.seen_retire = Signal()
        self.no_retire_cycles = Signal(max=threshold+1)
        self.last_pc, self.last_inst = Signal(64), Signal(32)
        self.stalls, self.pending, self.ages = [], [], []
        self.reason_names = ["no_retire"]
        triggers = [~(cpu.retire_valid != 0) & (self.no_retire_cycles >= threshold-1)]
        self.sync += If(cpu.retire_valid != 0,
            self.seen_retire.eq(1), self.no_retire_cycles.eq(0)
        ).Elif(self.no_retire_cycles < threshold,
            self.no_retire_cycles.eq(self.no_retire_cycles+1))
        for lane in range(4):
            self.sync += If(cpu.retire_valid[lane],
                self.last_pc.eq(cpu.retire_pc[64*lane:64*(lane+1)]),
                self.last_inst.eq(cpu.retire_inst[32*lane:32*(lane+1)]))
        for name, bus in (("memory", cpu.memory_bus), ("mmio", cpu.mmio_bus)):
            for channel in ("ar", "aw", "w", "r", "b"):
                ep = getattr(bus, channel)
                stalled = ep.valid & ~ep.ready
                counter = Signal(max=threshold+1)
                self.stalls.append(counter)
                self.reason_names.append(name+"_"+channel+"_stall")
                self.sync += If(~stalled, counter.eq(0)).Elif(counter < threshold,
                    counter.eq(counter+1))
                triggers.append(stalled & (counter >= threshold-1))
        for name, bus in (("memory", cpu.memory_bus), ("mmio", cpu.mmio_bus)):
            for channel, response in (("ar", "r"), ("aw", "b")):
                req, resp = getattr(bus, channel), getattr(bus, response)
                pending, age = Signal(), Signal(max=threshold+1)
                finish = resp.valid & resp.ready
                if name == "memory" and response == "r":
                    finish = finish & resp.last
                self.pending.append(pending); self.ages.append(age)
                self.reason_names.append(name+"_"+response+"_timeout")
                # One globally ordered read/write in flight through O3AxiRouter.
                self.sync += If(req.valid & req.ready, pending.eq(1), age.eq(0))
                self.sync += If(pending & ~finish & (age < threshold), age.eq(age+1))
                self.sync += If(finish, pending.eq(0), age.eq(0))
                triggers.append(pending & ~finish & (age >= threshold-1))
        trigger_bits = Cat(*triggers)
        self.sync += [self.reasons.eq(self.reasons | trigger_bits),
            If(trigger_bits != 0, self.hang.eq(1))]


class O3DebugILA(Module):
    def __init__(self, cpu, platform, threshold=10_000_000):
        self.submodules.watchdog = watch = O3Watchdog(cpu, threshold)
        self.hang = watch.hang
        signals, names = [], []
        def add(name, signal):
            names.append(name); signals.append(signal)
        for name, signal in (("retire_valid", cpu.retire_valid), ("retire_pc", cpu.retire_pc),
                ("retire_inst", cpu.retire_inst), ("retired_count", cpu.retired_count),
                ("last_retire_pc", watch.last_pc), ("last_retire_inst", watch.last_inst),
                ("seen_retire", watch.seen_retire), ("no_retire_cycles", watch.no_retire_cycles),
                ("hang", watch.hang), ("hang_reasons", watch.reasons),
                ("status", Cat(cpu.fatal, cpu.inclusion_err, cpu.dma_busy,
                    cpu.msip, cpu.mtip, cpu.meip, cpu.seip)), ("mtime_low", cpu.time[:32])):
            add(name, signal)
        for name, bus in (("memory", cpu.memory_bus), ("mmio", cpu.mmio_bus)):
            for channel in ("ar", "aw", "w", "r", "b"):
                ep = getattr(bus, channel)
                fields = [ep.valid, ep.ready]
                if channel in ("ar", "aw"):
                    fields += [ep.addr]
                    if name == "memory": fields += [ep.id, ep.len, ep.size, ep.burst]
                    else: fields += [ep.prot]
                elif channel == "w":
                    fields += [ep.strb]
                    if name == "memory": fields += [ep.last]
                    fields += [ep.data[:64]]
                elif channel == "r":
                    if name == "memory": fields += [ep.id, ep.last]
                    fields += [ep.resp, ep.data[:64]]
                else:
                    if name == "memory": fields += [ep.id]
                    fields += [ep.resp]
                add(name+"_"+channel, Cat(*fields))
        add("router_inflight", Cat(cpu.axi_router.read_dram, cpu.axi_router.read_low,
            cpu.axi_router.write_dram, cpu.axi_router.write_low))
        add("response_pending", Cat(*watch.pending))
        add("response_ages", Cat(*watch.ages))
        add("channel_stall_cycles", Cat(*watch.stalls))
        self.probes = [dict(probe=i, name=name, width=len(sig))
            for i, (name, sig) in enumerate(zip(names, signals))]
        self.reason_names = watch.reason_names
        self.threshold = threshold
        commands = platform.toolchain.pre_synthesis_commands
        commands.append("create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name o3_ila")
        settings = ["CONFIG.C_DATA_DEPTH 2048", f"CONFIG.C_NUM_OF_PROBES {len(signals)}"]
        settings += [f"CONFIG.C_PROBE{i}_WIDTH {len(sig)}" for i, sig in enumerate(signals)]
        commands.append("set_property -dict [list " + " ".join(settings) + "] [get_ips o3_ila]")
        commands.append("generate_target all [get_ips o3_ila]")
        platform.toolchain.additional_commands.append("write_debug_probes -force o3_ila.ltx")
        self.specials += Instance("o3_ila", i_clk=ClockSignal("sys"),
            **{f"i_probe{i}": sig for i, sig in enumerate(signals)})

    def write_probe_map(self, path):
        probes = [dict(probe) for probe in self.probes]
        for probe in probes:
            if probe["name"] == "hang_reasons":
                probe["reason_bits"] = {name:i for i,name in enumerate(self.reason_names)}
            if probe["name"] == "hang":
                probe["threshold_cycles"] = self.threshold
        Path(path).write_text(json.dumps(probes, indent=2)+"\n")
