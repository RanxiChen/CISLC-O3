import cocotb
from cocotb.triggers import Timer
async def settle():await Timer(1,unit='ns')
async def edge(d):
 d.clk_i.value=0;await settle();d.clk_i.value=1;await settle();d.clk_i.value=0;await settle()
def v(d,n):return int(getattr(d,n).value)
def event(d,e):return (v(d,'perf_o')>>((len(d.perf_o)//0x44)*e))&((1<<(len(d.perf_o)//0x44))-1)
async def reset(d):
 for n in ('clk_i','rst_i','valid_i','ready_i','hold_i','kill_i','pf_dis_i','va_i','id_i','priv_i','mode_i','asid_i','epoch_i','status_i','probe_grant_i','probe_valid_i','probe_hit_i','probe_g_i','probe_ppn_i','probe_level_i','fill_valid_i','fill_g_i','fill_vpn_i','fill_ppn_i','fill_level_i','fill_asid_i','fill_epoch_i','sf_i','rs1_x0_i','rs2_x0_i','sf_va_i','sf_asid_i'):getattr(d,n).value=0
 d.rst_i.value=1;await edge(d);d.rst_i.value=0;d.ready_i.value=1;d.priv_i.value=3
@cocotb.test()
async def bare_dedup_hold_kill_disable(d):
 await reset(d);d.valid_i.value=1;d.va_i.value=0x80000000
 await settle();assert v(d,'request_o') and v(d,'consumed_o') and event(d,0x2a)==event(d,0x2b)==1
 await edge(d);d.va_i.value=0x80000010;await settle()
 assert not v(d,'request_o') and v(d,'consumed_o') and event(d,0x2c)==1
 d.hold_i.value=1;await settle();assert not v(d,'consumed_o');await edge(d);d.hold_i.value=0
 d.kill_i.value=1;await edge(d);d.kill_i.value=0;await settle();assert v(d,'request_o')
 d.ready_i.value=0;await edge(d);assert v(d,'request_o') and not v(d,'consumed_o')
 d.pf_dis_i.value=1;await settle();assert v(d,'consumed_o') and not v(d,'request_o') and v(d,'perf_o')==0
 d.pf_dis_i.value=0;d.va_i.value=1<<60;await settle();assert v(d,'consumed_o') and not v(d,'request_o') and event(d,0x42)==1
@cocotb.test()
async def sv39_probe_hit_miss_and_discard(d):
 await reset(d);d.mode_i.value=8;d.priv_i.value=1;d.valid_i.value=1;d.va_i.value=0x402000
 d.probe_grant_i.value=1;await settle();assert v(d,'probe_o') and event(d,0x43)==1
 await edge(d);d.probe_grant_i.value=0;assert not v(d,'probe_o')
 d.probe_valid_i.value=1;d.probe_hit_i.value=1;d.probe_ppn_i.value=0x80002
 await edge(d);d.probe_valid_i.value=0;await settle()
 assert v(d,'request_o') and v(d,'pa_o')==0x80002000 and event(d,0x29)==1
 await edge(d);d.va_i.value=0x500000;d.id_i.value=2;d.probe_grant_i.value=1;await edge(d)
 d.probe_grant_i.value=0;d.probe_valid_i.value=1;d.probe_hit_i.value=0;await settle();assert v(d,'consumed_o') and event(d,0x42)==1
 await edge(d);d.probe_valid_i.value=0;d.va_i.value=0x600000;d.id_i.value=3;d.probe_grant_i.value=1;await edge(d)
 d.hold_i.value=1;d.probe_valid_i.value=1;d.probe_hit_i.value=1;await edge(d)
 d.hold_i.value=0;d.probe_valid_i.value=0;await settle();assert v(d,'probe_o') and not v(d,'request_o')
@cocotb.test()
async def superpage_context_and_sfence_ranges(d):
 for global_ in (0,1):
  for va_all in (0,1):
   for asid_all in (0,1):
    await reset(d);d.mode_i.value=8;d.priv_i.value=1;d.asid_i.value=7
    d.fill_valid_i.value=1;d.fill_vpn_i.value=0x400;d.fill_ppn_i.value=0x80200;d.fill_level_i.value=1;d.fill_g_i.value=global_;d.fill_asid_i.value=7
    await edge(d);d.fill_valid_i.value=0;d.valid_i.value=1;d.va_i.value=0x401fc0
    await settle();assert v(d,'request_o') and v(d,'pa_o')==0x80201fc0
    d.valid_i.value=0;d.sf_i.value=1;d.rs1_x0_i.value=va_all;d.rs2_x0_i.value=asid_all;d.sf_va_i.value=0x401000;d.sf_asid_i.value=7
    await edge(d);d.sf_i.value=0;d.valid_i.value=1;await settle()
    invalid=asid_all or not global_
    assert bool(v(d,'probe_o'))==bool(invalid)
    d.valid_i.value=0;d.epoch_i.value=1;await edge(d);d.valid_i.value=1;await settle();assert v(d,'probe_o')
