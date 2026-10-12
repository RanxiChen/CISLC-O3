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
                    await e.until(lambda:bool(e.stores))
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
    # Preserve the original four requests and add enough owners to fill the
    # configured capacity after the pipeline-credit increase.
    depth=val(d.cfg_fifo_o)
    for group in range(2,depth):
        await e.issue(e.uop(2*group+1,lq=2*group,rob=2*group),
                      e.uop(2*group+2,addr=0x80000110,lq=2*group+1,rob=2*group+1))
    await e.until(lambda:len({field(d,'response',a,'lq_tag.idx') for _,_,a in e.updates})==2*depth)
    for _ in range(12):
        await e.tick()
        assert not val(d.issue_ready_o[0]) and not val(d.issue_ready_o[1])
        assert [field(d,'result',val(d.load_result_o[p]),'instruction_id') for p in range(2)]==[1,2]
    e.hold_result=False
    for group in range(1,depth):
        await e.tick()
        assert all(field(d,'result',val(d.load_result_o[p]),'valid') for p in range(2))
        assert [field(d,'result',val(d.load_result_o[p]),'instruction_id') for p in range(2)]==[2*group+1,2*group+2]
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
    # R adds one edge after the raw cache return; the surviving older STA
    # must still finish even though the younger response was killed at S2.
    await e.until(lambda:bool(e.stores))
    assert e.stores[-1][2:]==(0x80000108,0x1122334455667788)
    for _ in range(12):await e.tick();assert not e.results


@cocotb.test()
async def dirty_refresh_keeps_young_load_asleep_until_owner_revalidates(d):
    """l10_ad first writer: refresh must not wake an AD_ORDER load early."""
    def bits(*pairs):
        value=0
        for width,part in pairs:
            assert 0 <= part < (1<<width)
            value=(value<<width)|part
        return value
    e=Bench(d);await e.reset()
    # dmmu_csr_t: priv_eff,priv,mprv,mpp,adue,sum,mxr,mode,asid,root,epoch.
    d.csr_i.value=bits((2,1),(2,1),(1,0),(2,0),(1,1),(1,0),(1,0),
                       (4,8),(16,0),(44,0x80100),(8,0))
    async def fill(dirty):
        await e.until(lambda:val(d.ptw_req_valid_o))
        d.ptw_req_ready_i.value=1;await e.tick();d.ptw_req_ready_i.value=0
        # ptw_resp_t public fields; VPN7 -> PA0x80103000, R/W/A, optional D.
        d.ptw_resp_i.value=bits((1,1),(27,7),(16,0),(8,0),(2,2),(44,0x80103),
            (2,0),(1,1),(1,1),(1,0),(1,0),(1,0),(1,1),(1,int(dirty)),
            (1,0),(1,0),(56,0x80102038),(64,0x20040c47|(0x80 if dirty else 0)))
        await e.tick();d.ptw_resp_i.value=0
    e.data=0x11223344
    await e.issue(e.uop(1,addr=0x7000,rob=1))
    await fill(False)
    await e.until(lambda:1 in e.waits)
    await e.replay(1);await e.until(lambda:bool(e.results))
    e.hold_result=False;await e.tick();await e.tick()
    await e.issue(e.uop(2,addr=0x7000,load=False,rob=14,value=0x55667788))
    await e.until(lambda:val(d.sq_capture_valid_o[0]))
    owner=val(d.capture_o[0])
    await e.until(lambda:bool(e.d_marks))
    # Younger load reaches AD_ORDER while the owner is waiting on D update.
    await e.issue(e.uop(3,addr=0x7000,rob=15,lq=2))
    await e.until(lambda:e.waits.get(2)==10)
    d.d_done_i.value=1;await e.tick();d.d_done_i.value=0
    for _ in range(5):
        await e.tick()
        assert not val(d.ad_wake_o), 'D refresh wakes younger LQ before owner revalidation'
    async def owner_replay():
        await e.until(lambda:val(d.sq_replay_ready_o[0]))
        d.sq_replay_i[0].value=owner;d.sq_replay_valid_i[0].value=1
        await e.tick();d.sq_replay_valid_i[0].value=0
    await owner_replay();await fill(True)
    for _ in range(5):await e.tick()
    await owner_replay();await e.until(lambda:bool(e.d_clears))
    assert e.d_clears[-1][1:]==(14,0x7000) and e.d_clears[-1][0] in e.ad_wakes
    e.forward=True;e.data=0x55667788
    await e.replay(2)
    await e.until(lambda:any(field(d,'result',r,'instruction_id')==3 for _,_,r in e.results))
    r=next(r for _,_,r in e.results if field(d,'result',r,'instruction_id')==3)
    assert field(d,'result',r,'result')==0x55667788


@cocotb.test()
async def continuous_two_lane_hits_keep_one_packet_per_cycle_after_translation_split(d):
    e=Bench(d);await e.reset();e.data=0x5566778899aabbcc;e.hold_result=False
    accepted=[];packets=48;send_cycles=[]
    for cycle in range(100):
        ready=all(val(d.issue_ready_o[p]) for p in range(2))
        if len(accepted)<packets and ready:
            ident=2*len(accepted)+1
            array(d.mem_uop_i,[e.uop(ident,lq=cycle%16,rob=cycle%val(d.cfg_rob_o)),
                e.uop(ident+1,addr=0x80000110,lq=(cycle+1)%16,rob=(cycle+1)%val(d.cfg_rob_o))])
            accepted.append((ident,ident+1));send_cycles.append(e.cycle)
        else:array(d.mem_uop_i,[0,0])
        await e.tick()
        if len(e.results)==2*packets:break
    assert len(accepted)==packets and len(e.results)==2*packets
    assert send_cycles==list(range(send_cycles[0],send_cycles[0]+packets)),send_cycles
    for lane in range(2):
        got=[field(d,'result',raw,'instruction_id') for _,p,raw in e.results if p==lane]
        assert got==[pair[lane] for pair in accepted]
        result_cycles=[c for c,p,_ in e.results if p==lane]
        assert result_cycles==list(range(result_cycles[0],result_cycles[0]+packets))
        assert all(field(d,'result',raw,'result')==e.data for _,p,raw in e.results if p==lane)


@cocotb.test()
async def response_boundary_identity_cancel_and_early_notice(d):
    """Capture both raw returns, then kill/resolve in the new R stage.

    The external cache agent keeps the original fixed cache protocol. Its full
    owner/data packet must survive the extra edge, and the notification precedes
    actual result visibility by exactly one cycle. No private pipeline signals.
    """
    rng=random.Random(105)
    for transaction in range(192):
        e=Bench(d);await e.reset();e.data=rng.getrandbits(64)
        tag=transaction%val(d.cfg_tags_o);bit=1<<tag
        kill=transaction%3==0;flush=transaction%7==0
        pair=[e.uop(2*transaction+1,mask=bit,rob=3,lq=0),
              e.uop(2*transaction+2,mask=0,rob=2,lq=1)]
        pair=[u|codec(d,'uop',dst_write_en=1) for u in pair]
        await e.issue(*pair)
        await e.until(lambda:all(e.reply))
        assert not e.updates and not e.wakes and not e.results
        await e.tick()  # actual cache return captured at R boundary
        assert not e.updates and not e.wakes and not e.results
        d.resolution_valid_i.value=1;d.resolution_tag_i.value=tag
        d.resolution_mispredict_i.value=int(kill);d.flush_all_i.value=int(flush)
        await e.tick()
        d.resolution_valid_i.value=0;d.resolution_mispredict_i.value=0;d.flush_all_i.value=0
        expected=[] if flush else ([pair[1]] if kill else pair)
        for _ in range(12):await e.tick()
        got=[field(d,'result',r,'instruction_id') for _,_,r in e.results[:len(expected)]]
        want=[field(d,'uop',u,'instruction_id') for u in expected]
        assert got==want,(transaction,got,want)
        # The held FIFO head may be sampled repeatedly; every visible packet
        # keeps its correct owner, payload and resolved branch mask.
        for c,lane,raw in e.results:
            assert field(d,'result',raw,'instruction_id') in want
            assert field(d,'result',raw,'result')==e.data
            assert field(d,'result',raw,'branch_mask')==0
        assert len(e.wakes)==len(expected),(transaction,e.wakes)
        for wc,lane,promise in e.wakes:
            assert field(d,'wake',promise,'preg')==7
            assert field(d,'wake',promise,'br_mask')==0
            first=min(c for c,p,_ in e.results if p==lane)
            assert first==wc+1,(transaction,wc,first)
