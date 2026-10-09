#!/usr/bin/env python3
"""Frozen H1-H3 watchdog checks with short generated thresholds, all 15 reasons."""
import sys
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'litex_wrapper'))
from migen import Module, Signal
from migen.sim import run_simulation
from litex.soc.interconnect import axi
from o3.ila import O3DebugILA, O3Watchdog


def make_cpu():
    return SimpleNamespace(retire_valid=Signal(4),retire_pc=Signal(256),retire_inst=Signal(128),
        retired_count=Signal(64),memory_bus=axi.AXIInterface(data_width=128,address_width=32,id_width=4),
        mmio_bus=axi.AXILiteInterface(data_width=64,address_width=32),
        fatal=Signal(),inclusion_err=Signal(),dma_busy=Signal(),msip=Signal(),mtip=Signal(),
        meip=Signal(),seip=Signal(),time=Signal(64),
        axi_router=SimpleNamespace(read_dram=Signal(),read_low=Signal(),write_dram=Signal(),write_low=Signal()))


def check_reason(index):
    cpu=make_cpu(); top=Module(); top.submodules.watch=watch=O3Watchdog(cpu,threshold=4)
    def test():
        if index:
            yield cpu.retire_valid.eq(1)
        yield
        if index==0:
            # Include the initial idle cycle in the no-retire count.
            for _ in range(3):
                assert not (yield watch.hang)
                yield
        elif index<=10:
            bus=cpu.memory_bus if index<=5 else cpu.mmio_bus
            channel=('ar','aw','w','r','b')[(index-1)%5]
            ep=getattr(bus,channel)
            yield ep.valid.eq(1); yield ep.ready.eq(0)
            for _ in range(4):
                assert not (yield watch.hang)
                yield
            yield
            assert (yield ep.valid)==1 and (yield ep.ready)==0
            yield ep.valid.eq(0)
        else:
            bus=cpu.memory_bus if index<=12 else cpu.mmio_bus
            request='ar' if index in (11,13) else 'aw'
            ep=getattr(bus,request)
            yield ep.valid.eq(1);yield ep.ready.eq(1)
            yield
            yield
            yield ep.valid.eq(0)
            for _ in range(4):
                assert not (yield watch.hang)
                yield
            yield
        assert (yield watch.hang) and (yield watch.reasons)==1<<index, (index,(yield watch.reasons))
        for _ in range(7):
            yield
            assert (yield watch.hang) and (yield watch.reasons)&(1<<index)
        for counter in [watch.no_retire_cycles]+watch.stalls+watch.ages:
            assert (yield counter)<=4
    run_simulation(top,test())


def check_completion_and_retirement():
    cpu=make_cpu(); top=Module();top.submodules.watch=watch=O3Watchdog(cpu,threshold=4)
    def test():
        yield cpu.retire_valid.eq(9)
        yield cpu.retire_pc.eq(0x1020|(0x3040<<192))
        yield cpu.retire_inst.eq(0x12345678|(0x89abcdef<<96))
        yield
        yield
        assert (yield watch.seen_retire) and (yield watch.last_pc)==0x3040
        assert (yield watch.last_inst)==0x89abcdef
        yield cpu.memory_bus.ar.valid.eq(1);yield cpu.memory_bus.ar.ready.eq(1)
        yield
        yield
        yield cpu.memory_bus.ar.valid.eq(0)
        yield cpu.memory_bus.r.valid.eq(1);yield cpu.memory_bus.r.ready.eq(1)
        yield cpu.memory_bus.r.last.eq(0)
        yield
        yield
        assert (yield watch.pending[0])==1
        yield cpu.memory_bus.r.last.eq(1)
        yield
        yield
        yield cpu.memory_bus.r.valid.eq(0)
        for _ in range(8):
            yield
            assert not (yield watch.hang) and not (yield watch.reasons)
            assert (yield watch.pending[0])==0
    run_simulation(top,test())


def main():
    for reason in range(15):check_reason(reason)
    check_completion_and_retirement()
    toolchain=SimpleNamespace(pre_synthesis_commands=[],additional_commands=[])
    ila=O3DebugILA(make_cpu(),SimpleNamespace(toolchain=toolchain))
    names={p['name'] for p in ila.probes}
    assert {'mtime_low','last_retire_pc','last_retire_inst','hang','hang_reasons','router_inflight'}<=names
    assert all(bus+'_'+channel in names for bus in ('memory','mmio') for channel in ('ar','aw','w','r','b'))
    assert len(ila.reason_names)==15 and len(ila.probes)==26
    assert 'write_debug_probes -force o3_ila.ltx' in toolchain.additional_commands
    print('PASS: 15 sticky reasons, threshold/saturation, retirement, RLAST completion; 26 ILA probes and .ltx export')


if __name__=='__main__':main()
