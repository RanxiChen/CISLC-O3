import cocotb
from l8a_lsu_agents import Bench
from l3_contract import *

@cocotb.test()
async def every_crossline_offset_integer_fp_load_store_defers_without_cache_access(d):
    for size in (1,2,3):
        for offset in range(65-(1<<size),64):
            for load in (False,True):
                for fp in ((False,True) if size in (2,3) else (False,)):
                    e=Bench(d);await e.reset()
                    u=e.uop(42,addr=0x80001000+offset,load=load,value=0x8877665544332211)
                    u=(u&~val(d.fmt_uop_mem_size))|codec(d,'uop',mem_size=size)
                    if fp:u=(u&~val(d.fmt_uop_dst_dom))|codec(d,'uop',dst_dom=2)
                    await e.issue(u)
                    for _ in range(8):await e.tick()
                    assert not e.requests and not e.results,(size,offset,load,fp,'spec 7 no early cache access')
                    if load:
                        assert len(e.updates)==1 and field(d,'response',e.updates[0][2],'reason')==11
                    else:
                        assert len(e.stores)==1 and e.stores[0][3]==0x8877665544332211
                    assert not any(val(d.store_complete_valid_o[p]) for p in range(2))

@cocotb.test()
async def s1_sq_query_not_gated_by_translation_exception(d):
    e=Bench(d);await e.reset();await e.issue(e.uop(7,addr=0x100000000))
    observed=False
    for _ in range(10):
        # Address exceeds physical width, so S1 has a real translation exception.
        for p in range(2):
            q=val(d.dc_s1_o[p])
            if val(d.sq_query_valid_o[p]):
                assert field(d,'request',q,'exc')>>70;observed=True
        await e.tick()
    assert observed,'Y14 SQ query was suppressed by exception'
    assert e.exceptions and not e.results

@cocotb.test()
async def atomic_agu_uses_sq_and_no_translation_or_l1d(d):
    e=Bench(d);await e.reset();d.atomic_i[0].value=1
    await e.issue(e.uop(7,addr=0x80001000,load=False,value=0x1234))
    for _ in range(8):await e.tick()
    assert not e.requests and not e.results and len(e.stores)==1
    assert not val(d.ptw_req_valid_o)


@cocotb.test()
async def head_high_half_translation_fault_preserves_first_high_va(d):
    def bits(*pairs):
        value=0
        for width,part in pairs:value=(value<<width)|part
        return value
    for write in (0,1):
        e=Bench(d);await e.reset()
        # Sv39 S-mode, valid low half comes from a separate mapped page.
        d.csr_i.value=bits((2,1),(2,1),(1,0),(2,0),(1,1),(1,0),(1,0),
                           (4,8),(16,0),(44,0x80100),(8,0))
        hi=0x5000
        d.heu_req_i.value=codec(d,'request',head=1,vaddr=hi,size=3,bytes=7,split=1,raw=1,check_only=1,write=write,rob_idx=0)
        d.heu_valid_i.value=1
        await e.until(lambda:val(d.heu_ready_o));await e.tick();d.heu_valid_i.value=0
        await e.until(lambda:val(d.ptw_req_valid_o))
        d.ptw_req_ready_i.value=1;await e.tick();d.ptw_req_ready_i.value=0
        d.ptw_resp_i.value=bits((1,1),(27,5),(16,0),(8,0),(2,2),(44,0),
            (2,0),(1,0),(1,0),(1,0),(1,0),(1,0),(1,0),(1,0),
            (1,1),(1,0),(56,0),(64,0))
        await e.tick();d.ptw_resp_i.value=0
        for _ in range(4):await e.tick()
        e.head_replies.clear();d.heu_valid_i.value=1
        await e.until(lambda:val(d.heu_ready_o));await e.tick();d.heu_valid_i.value=0
        await e.until(lambda:bool(e.head_replies))
        response=e.head_replies[-1];exc=field(d,'response',response,'exc')
        assert field(d,'response',response,'status')==3
        assert exc==(1<<70)|((15 if write else 13)<<64)|hi
        assert not e.stores and not e.results,'check-only half must have no architectural writes'
