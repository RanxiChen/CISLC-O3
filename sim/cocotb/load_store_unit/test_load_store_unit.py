import os
import random
import cocotb
from l3_contract import val,field,codec,array,clear
from l8a_lsu_agents import Bench,INPUTS


@cocotb.test()
async def blocked_load_replays_after_older_store_executes(d):
    e=Bench(d);await e.reset();e.block=True
    await e.issue(e.uop(42))
    await e.until(lambda: e.waits.get(1)==1)
    assert not e.results
    for _ in range(12):await e.tick();assert not e.results
    await e.issue(e.uop(8,load=False,rob=1,value=0x1122334455667788))
    await e.until(lambda: bool(e.stores))
    assert e.stores[-1][2:]==(0x80000108,0x1122334455667788)
    # The independent SQ agent now exposes the complete older store.
    e.block=False;e.forward=True;e.data=0x1122334455667788
    await e.replay(1)
    await e.until(lambda: bool(e.results))
    r=e.results[-1][2]
    assert field(d,'result',r,'instruction_id')==42
    assert field(d,'result',r,'result')==0x1122334455667788
    assert e.requests[-1][2]==0x80000108


@cocotb.test()
async def wrong_path_replay_is_cancelled(d):
    e=Bench(d);await e.reset();e.block=True
    await e.issue(e.uop(5,addr=0x80000100,mask=1))
    await e.until(lambda: e.waits.get(1)==1)
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=0
    await e.tick();d.resolution_valid_i.value=0;d.resolution_mispredict_i.value=0
    e.block=False;e.forward=True;e.data=0x55
    assert not e.saved and not e.waits
    for _ in range(12):await e.tick();assert not e.results


@cocotb.test()
async def seeded_c_m_replay_pending_response_result_backpressure(d):
    rng=random.Random(int(os.getenv('TEST_SEED','1')))
    for transaction in range(160):
        e=Bench(d);await e.reset()
        ident=transaction+1;data=rng.getrandbits(64);tags=val(d.cfg_tags_o);tag=transaction%tags
        mask=(1<<tag)|(1<<((tag+3)%tags));mode=transaction%3;kill=transaction%4==0
        e.data=data;e.block=mode==1;e.forward=mode==0;e.miss=mode==2
        await e.issue(e.uop(ident,addr=0x80010000+8*(transaction%8),mask=mask,rob=transaction%val(d.cfg_rob_o),lq=transaction%val(d.cfg_lq_o)))
        idx=transaction%val(d.cfg_lq_o)
        if mode:
            await e.until(lambda: idx in e.waits)
            for _ in range(rng.randrange(1,6)):
                await e.tick();assert not e.results
            if kill and mode==1:
                # Retain the original random old-STA-on-M coverage in every
                # such transaction, using its real fixed S2 completion edge.
                await e.issue(e.uop(ident+1000,load=False,addr=0x80020000,
                                    lq=idx,rob=0,value=data))
                await e.until(lambda:any(e.reply))
            d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=int(kill);d.resolution_tag_i.value=tag
            await e.tick();d.resolution_valid_i.value=0;d.resolution_mispredict_i.value=0
            mask&=~(1<<tag)
            if kill:
                if mode==1:
                    assert e.stores[-1][2:]==(0x80020000,data),(transaction,'old STA on M')
                assert idx not in e.saved and idx not in e.waits
                e.miss=False;e.block=False
                for _ in range(5):await e.tick();assert not e.results
                continue
            e.miss=False;e.block=False;e.forward=True
            await e.replay(idx)
        else:
            # Correct resolution coincides with S2/fifo creation, not just RR.
            await e.until(lambda: any(e.reply))
            d.resolution_valid_i.value=1;d.resolution_tag_i.value=tag
            await e.tick();d.resolution_valid_i.value=0
            mask&=~(1<<tag)
        await e.until(lambda: bool(e.results))
        r=e.results[-1][2]
        assert field(d,'result',r,'instruction_id')==ident
        assert field(d,'result',r,'result')==data
        assert field(d,'result',r,'branch_mask')==mask,(transaction,mode,mask,field(d,'result',r,'branch_mask'))
        for _ in range(rng.randrange(1,6)):
            d.resolution_valid_i.value=1;d.resolution_tag_i.value=(tag+3)%tags
            await e.tick();mask&=~(1<<((tag+3)%tags))
            raw=val(d.load_result_o[0])
            assert field(d,'result',raw,'valid') and field(d,'result',raw,'instruction_id')==ident
            assert field(d,'result',raw,'result')==data and field(d,'result',raw,'branch_mask')==mask
        d.resolution_valid_i.value=0;e.hold_result=False
        await e.tick();await e.tick()
        assert not field(d,'result',val(d.load_result_o[0]),'valid')


@cocotb.test()
async def two_lane_results_and_fifo_reservations(d):
    e=Bench(d);await e.reset();e.data=0xaabbccdd
    await e.issue(e.uop(1,lq=0),e.uop(2,addr=0x80000110,lq=1,rob=3))
    await e.until(lambda: all(field(d,'result',val(d.load_result_o[p]),'valid') for p in range(2)))
    assert [field(d,'result',val(d.load_result_o[p]),'instruction_id') for p in range(2)]==[1,2]
    await e.issue(e.uop(3,lq=2),e.uop(4,lq=3,rob=4))
    await e.until(lambda: len({field(d,'response',a,'lq_tag.idx') for _,_,a in e.updates})==4)
    for _ in range(12):
        await e.tick()
        assert not val(d.issue_ready_o[0]) and not val(d.issue_ready_o[1])
        assert [field(d,'result',val(d.load_result_o[p]),'instruction_id') for p in range(2)]==[1,2]
    e.hold_result=False;await e.tick()
    assert all(field(d,'result',val(d.load_result_o[p]),'valid') for p in range(2))
    assert [field(d,'result',val(d.load_result_o[p]),'instruction_id') for p in range(2)]==[3,4]
    await e.tick();await e.tick()
    assert all(not field(d,'result',val(d.load_result_o[p]),'valid') for p in range(2))


@cocotb.test()
async def mispredict_at_s2_cancels_young_but_keeps_old_store(d):
    e=Bench(d);await e.reset();e.data=0x55
    # An older STA and younger load reach S2 together; the branch kills only
    # the load although its fixed-latency response is already in flight.
    await e.issue(e.uop(8,load=False,lq=0,rob=1,value=0x1122334455667788),
                  e.uop(5,lq=1,rob=2,mask=1))
    await e.until(lambda:any(e.reply))
    d.resolution_valid_i.value=1;d.resolution_mispredict_i.value=1;d.resolution_tag_i.value=0
    await e.tick();d.resolution_valid_i.value=0;d.resolution_mispredict_i.value=0
    assert e.stores[-1][2:]==(0x80000108,0x1122334455667788)
    for _ in range(12):await e.tick();assert not e.results
