import cocotb
from l3_contract import *

INPUTS=['clk','rst','start_valid_i','sq_empty_i','flush_i','start_i','rob_head_i','dc_ready_i','dc_resp_i','wake_i','tlb_wake_i','d_ready_i','d_done_i','d_exc_i','sfence_done_i','mmio_ready_i','mmio_resp_i','cache_irreversible_i','mmio_irreversible_i','result_ready_i','exc_ready_i']
async def wait(d,port,limit=40):
    for _ in range(limit):
        await settle()
        if (field(d,'result',val(d.result_o),'valid') if port=='result_o' else val(getattr(d,port))):return
        await tick(d)
    assert False,'watchdog '+port

async def start(d,kind=1,write=1,va=0x80001000,size=3,fp=False):
    await reset(d,INPUTS);d.sq_empty_i.value=1;d.rob_head_i.value=7
    d.start_i.value=codec(d,'start',**{'tag.rob_idx':7,'tag.dst_write_en':int(not write or kind==1),'tag.dst_dom':2 if fp else 1,'tag.dst_preg':5,'kind':kind,'va':va,'size':size,'write':write,'data':0x8877665544332211,'is_flw':int(fp and size==2)})
    d.start_valid_i.value=1;await settle();assert val(d.start_ready_o)
    await tick(d);d.start_valid_i.value=0

async def cache(d,check,va,raw=0,io=False,exc=0):
    await wait(d,'dc_valid_o');q=val(d.dc_req_o)
    assert field(d,'request',q,'check_only')==check
    assert field(d,'request',q,'vaddr')==va
    d.dc_ready_i.value=1;await tick(d);d.dc_ready_i.value=0
    d.dc_resp_i.value=codec(d,'response',valid=1,status=3 if exc else 0,paddr=va&0xffffffff,rdata=raw,io=int(io),exc=exc)
    await tick(d);d.dc_resp_i.value=0
    return q

@cocotb.test()
async def four_classes_start_only_head_empty_and_no_flush(d):
    for kind,write in ((1,1),(2,0),(3,0),(3,1)):
        await reset(d,INPUTS)
        d.start_i.value=codec(d,'start',**{'tag.rob_idx':7,'kind':kind,'write':write})
        d.start_valid_i.value=1
        for head,empty,flush in ((6,1,0),(7,0,0),(7,1,1)):
            d.rob_head_i.value=head;d.sq_empty_i.value=empty;d.flush_i.value=flush
            await settle();assert not val(d.start_ready_o)
            await tick(d);assert not val(d.dc_valid_o) and not val(d.mmio_valid_o)
        d.flush_i.value=0;d.rob_head_i.value=7;d.sq_empty_i.value=1
        await settle();assert val(d.start_ready_o)

@cocotb.test()
async def atomic_result_held_no_reexecution_and_flush_before_effect_cancels(d):
    await start(d);await cache(d,1,0x80001000);await cache(d,0,0x80001000,0xdeadbeef)
    await wait(d,'result_o');expected=val(d.result_o)
    for _ in range(16):
        assert val(d.result_o)==expected and not val(d.dc_valid_o)
        await tick(d)
    assert field(d,'result',expected,'data')==0xdeadbeef
    d.result_ready_i.value=1;await tick(d);assert not field(d,'result',val(d.result_o),'valid')
    await start(d);d.flush_i.value=1;await tick(d);d.flush_i.value=0;await settle()
    assert not val(d.dc_valid_o) and not val(d.mmio_valid_o) and val(d.start_ready_o)

@cocotb.test()
async def mmio_issued_once_irreversible_survives_flush_and_wb_hold(d):
    await start(d,2,0,0x02000100);await cache(d,1,0x02000100,io=True)
    await wait(d,'mmio_valid_o');d.mmio_ready_i.value=1;await tick(d);d.mmio_ready_i.value=0
    assert val(d.irreversible_o);d.flush_i.value=1;await tick(d);d.flush_i.value=0
    for _ in range(12):await tick(d);assert not val(d.mmio_valid_o)
    d.mmio_resp_i.value=codec(d,'response',valid=1,rdata=0x1234)
    await tick(d);d.mmio_resp_i.value=0
    for _ in range(16):
        assert field(d,'result',val(d.result_o),'valid') and field(d,'result',val(d.result_o),'data')==0x1234
        assert not val(d.mmio_valid_o);await tick(d)
    d.result_ready_i.value=1;await tick(d);assert not val(d.irreversible_o)

@cocotb.test()
async def split_all_offsets_integer_fp_format_and_two_checks_before_writes(d):
    for size in (1,2,3):
        for off in range(65-(1<<size),64):
            for fp in ((False,True) if size>=2 else (False,)):
                for write in (0,1):
                    va=0x80001000+off;n=64-off
                    await start(d,3,write,va,size,fp)
                    await cache(d,1,va);await cache(d,1,0x80001040)
                    raw=0x8877665544332211&((1<<(8*(1<<size)))-1)
                    lo=await cache(d,0,va,raw&((1<<(8*n))-1))
                    assert field(d,'request',lo,'bytes')==n
                    if write:
                        d.cache_irreversible_i.value=1;await tick(d);d.cache_irreversible_i.value=0
                    hi=await cache(d,0,0x80001040,raw>>(8*n))
                    assert field(d,'request',hi,'bytes')==(1<<size)-n
                    if write:
                        assert val(d.done_o) and val(d.irreversible_o)
                    else:
                        await wait(d,'result_o');expected=raw | (0xffffffff00000000 if fp and size==2 else 0)
                        assert field(d,'result',val(d.result_o),'data')==expected,(size,off,fp)

@cocotb.test()
async def high_page_fault_has_high_tval_and_neither_half_written(d):
    for write in (0,1):
        va=0x80001fff;hi=0x80002000
        await start(d,3,write,va)
        await cache(d,1,va)
        exc=(1<<70)|((15 if write else 13)<<64)|hi
        await cache(d,1,hi,exc=exc)
        await wait(d,'exc_valid_o');assert val(d.exc_o)==exc and val(d.exc_idx_o)==7
        for _ in range(12):
            assert not val(d.dc_valid_o) and not val(d.irreversible_o)
            await tick(d)

@cocotb.test()
async def store_dirty_update_waits_sfence_before_second_half(d):
    await start(d,3,1,0x80001fff)
    await wait(d,'dc_valid_o');d.dc_ready_i.value=1;await tick(d);d.dc_ready_i.value=0
    d.dc_resp_i.value=codec(d,'response',valid=1,paddr=0x80001fff,need_d=1)
    await tick(d);d.dc_resp_i.value=0;await wait(d,'d_valid_o')
    assert val(d.d_va_o)==0x80001fff
    d.d_ready_i.value=1;await tick(d);d.d_ready_i.value=0
    d.d_done_i.value=1;await tick(d);d.d_done_i.value=0
    assert val(d.sfence_o)
    await tick(d)
    for _ in range(8):await tick(d);assert not val(d.dc_valid_o)
    d.sfence_done_i.value=1;await tick(d);d.sfence_done_i.value=0
    await cache(d,1,0x80001fff);await cache(d,1,0x80002000)
