import cocotb
from l8a_agents import *
from test_dcache import env


@cocotb.test()
async def miss_install_and_replay(dut):
    e=await env(dut)
    e.block_gets=True
    r=(await e.issue(Cpu(BASE)))[0]
    assert r['status']==MISS and r['reason']==MSHR
    e.block_gets=False
    start=len(e.wakes)
    await e.until(lambda: any(w['valid'] and w['mshr']==r['mshr'] for _,w in e.wakes[start:]))
    assert any(w['free'] for _,w in e.wakes[start:])
    r=await e.load(BASE)
    assert r['status']==OK and r['data']==e.golden(BASE)
    await e.idle()


@cocotb.test()
async def dual_different_bank_hit(dut):
    e=await env(dut)
    await e.load(BASE)
    r=await e.issue(Cpu(BASE,ident=1),Cpu(BASE+8,ident=2,lane=1,rob=2))
    assert all(x['status']==OK for x in r)
    assert [x['data'] for x in r]==[e.golden(BASE),e.golden(BASE+8)]
    await e.idle()


@cocotb.test()
async def same_bank_different_set_replay(dut):
    e=await env(dut)
    await e.load(BASE);await e.load(BASE+64)
    r=await e.issue(Cpu(BASE,ident=1),Cpu(BASE+64,ident=2,lane=1,rob=2))
    assert r[0]['status']==OK and r[0]['data']==e.golden(BASE)
    assert r[1]['status']==REPLAY and r[1]['reason']==BANK
    assert (await e.load(BASE+64))['data']==e.golden(BASE+64)
    await e.idle()


@cocotb.test()
async def same_line_merge_one_get(dut):
    e=await env(dut)
    e.block_gets=True
    r=await e.issue(Cpu(BASE,ident=1),Cpu(BASE+8,ident=2,lane=1,rob=2))
    assert all(x['status']==MISS for x in r) and r[0]['mshr']==r[1]['mshr']
    await e.until(lambda: len(e.sent)==1)
    assert sum(x[1]=='get' for x in e.events)==1
    e.block_gets=False
    assert (await e.load(BASE))['data']==e.golden(BASE)
    assert (await e.load(BASE+8))['data']==e.golden(BASE+8)
    await e.idle()


@cocotb.test()
async def drain_hit_e_ps_to_m(dut):
    e=await env(dut)
    await e.load(BASE)
    assert e.state(BASE)==2
    before=sum(x[1]=='get' for x in e.events)
    await e.store(BASE+8,0xaabbccddeeff1234)
    assert e.state(BASE)==3
    assert sum(x[1]=='get' for x in e.events)==before
    assert (await e.load(BASE+8))['data']==0xaabbccddeeff1234
    await e.idle()


@cocotb.test()
async def drain_shared_upgrade_acke(dut):
    e=await env(dut)
    e.shared.add(BASE>>6)
    await e.load(BASE)
    assert e.state(BASE)==1
    await e.store(BASE,0x1234)
    assert any(x[1]=='grant' and x[2]==ACKE for x in e.events)
    assert (await e.load(BASE))['data']==0x1234
    await e.idle()


@cocotb.test()
async def drain_miss_getm(dut):
    e=await env(dut)
    await e.store(BASE,0xabc123)
    assert any(x[1]=='get' and x[2]==GETM for x in e.events)
    assert (await e.load(BASE))['data']==0xabc123
    await e.idle()


@cocotb.test()
async def inv_m_dirty_response(dut):
    e=await env(dut)
    await e.store(BASE,0xdecaf123)
    q=await e.probe(BASE)
    assert q['op']==1 and q['dirty']==1 and q['data']==e.gold[BASE>>6]
    assert e.state(BASE)==0
    assert (await e.load(BASE))['data']==0xdecaf123
    await e.idle()


@cocotb.test()
async def down_m_dirty_response(dut):
    e=await env(dut)
    await e.store(BASE,0xfeedabba)
    q=await e.probe(BASE,down=True)
    assert q['op']==2 and q['dirty']==1 and q['data']==e.gold[BASE>>6]
    assert e.state(BASE)==1
    assert (await e.load(BASE))['data']==0xfeedabba
    await e.idle()


@cocotb.test()
async def ptw_read_miss_and_hit(dut):
    e=await env(dut)
    for _ in range(2):
        start=len(e.ptw_responses)
        e.ptw=Cpu(BASE+8,src=3)
        await e.until(lambda: len(e.ptw_responses)>start)
        r=e.ptw_responses[-1][1]
        assert r['status']==OK and r['data']==e.golden(BASE+8)
    assert sum(x[1]=='get' for x in e.events)==1
    await e.idle()


@cocotb.test()
async def pte_ad_compare_success_and_mismatch(dut):
    e=await env(dut)
    addr=BASE+8;original=e.golden(addr)
    e.ad=(addr,original,1,1,0)
    await e.until(lambda: e.ad_responses)
    assert e.ad_responses[-1][1]==12
    e.gold[BASE>>6]=e.initial(BASE>>6)&~(0xffffffffffffffff<<64)|(original|0xc0)<<64
    assert (await e.load(addr))['data']==original|0xc0
    e.ad=(addr,original,1,1,0)
    await e.until(lambda: len(e.ad_responses)==2)
    assert e.ad_responses[-1][1]==10
    assert (await e.load(addr))['data']==original|0xc0
    await e.idle()


@cocotb.test()
async def refill_error_install_err_keeps_i(dut):
    e=await env(dut)
    e.errors.add(BASE>>6)
    r=(await e.issue(Cpu(BASE)))[0]
    assert r['status']==MISS
    await e.until(lambda: any(w['valid'] and w['err'] and w['mshr']==r['mshr'] for _,w in e.wakes))
    assert e.state(BASE)==0
    e.errors.clear()
    assert (await e.load(BASE))['data']==e.golden(BASE)
    await e.idle()


@cocotb.test()
async def pa_high_bits_access_fault(dut):
    e=await env(dut)
    addr=(1<<32)+BASE
    r=(await e.issue(Cpu(addr,va=0x12345678)))[0]
    assert r['status']==ERROR
    assert r['exc']>>70==1 and (r['exc']>>64)&63==5 and r['exc']&((1<<64)-1)==0x12345678
    assert not e.events
    await e.idle()


@cocotb.test()
async def four_lines_in_flight_and_full_wakeup(dut):
    e=await env(dut)
    assert e.n==4
    e.block_gets=True
    answers=[]
    for k in range(4):
        r=(await e.issue(Cpu(BASE+k*64,ident=k+1,head=k==3)))[0]
        assert r['status']==MISS
        answers.append(r)
    await e.until(lambda: len(e.sent)==4)
    assert len({r['mshr'] for r in answers})==4 and int(dut.mon_ms_valid.value)==15
    r=(await e.issue(Cpu(BASE+4*64,ident=5)))[0]
    assert r['status']==REPLAY and r['reason']==FULL
    start=len(e.wakes);e.block_gets=False
    await e.until(lambda: any(w['free'] for _,w in e.wakes[start:]))
    for k in range(5):
        assert (await e.load(BASE+k*64))['data']==e.golden(BASE+k*64)
    await e.idle()


@cocotb.test()
async def reserved_last_mshr_head_only(dut):
    e=await env(dut)
    assert e.n==4
    e.block_gets=True
    for k in range(3):
        assert (await e.issue(Cpu(BASE+k*64,head=False)))[0]['status']==MISS
    r=(await e.issue(Cpu(BASE+3*64,head=False)))[0]
    assert r['status']==REPLAY and r['reason']==FULL
    assert int(dut.mon_ms_valid.value).bit_count()==3
    assert (await e.issue(Cpu(BASE+3*64,head=True)))[0]['status']==MISS
    assert int(dut.mon_ms_valid.value)==15
    e.block_gets=False
    await e.idle()


@cocotb.test()
async def clean_victim_put_without_data(dut):
    e=await env(dut)
    for k in range(e.ways+1):
        await e.load(BASE+k*e.sets*64)
    await e.idle()
    puts=[q for _,q in e.up if q['op']==0]
    assert puts and all(q['dirty']==0 for q in puts)


@cocotb.test()
async def wb_line_replay_until_ack(dut):
    e=await env(dut)
    for k in range(e.ways):
        await e.load(BASE+k*e.sets*64)
    e.block_putacks=True
    r=await e.load(BASE+e.ways*e.sets*64)
    assert r['status']==OK
    puts=[q for _,q in e.up if q['op']==0]
    assert puts
    victim=puts[-1]['line']<<6
    before=sum(x[1]=='get' and x[3]==victim>>6 for x in e.events)
    r=(await e.issue(Cpu(victim)))[0]
    assert r['status']==REPLAY and r['reason']==WB_LINE
    assert sum(x[1]=='get' and x[3]==victim>>6 for x in e.events)==before
    start=len(e.wakes);e.block_putacks=False
    await e.until(lambda: any(w['wb_free'] for _,w in e.wakes[start:]))
    assert (await e.load(victim))['data']==e.golden(victim)
    await e.idle()


@cocotb.test()
async def probe_waits_for_grant_install(dut):
    e=await env(dut)
    e.block_gets=True
    r=(await e.issue(Cpu(BASE)))[0]
    assert r['status']==MISS
    await e.until(lambda: len(e.sent)==1)
    e.snp=(0,1,BASE>>6)
    await e.until(lambda: e.snp_sent)
    for _ in range(20):
        await e.tick()
        assert not e.up
    e.block_gets=False
    await e.until(lambda: e.snp is None)
    install=next(c for c,w in e.wakes if w['valid'] and w['mshr']==r['mshr'])
    assert e.up[0][0]>install
    assert e.state(BASE)==0
    await e.idle()


@cocotb.test()
async def refill_snapshot_replay(dut):
    e=await env(dut)
    await e.load(BASE)
    e.block_gets=True
    assert (await e.issue(Cpu(BASE+e.sets*64)))[0]['status']==MISS
    await e.until(lambda: bool(e.pending) and e.pending[0][0]<=e.cycle)
    # Reserve before allowing the grant. S0 then reads a snapshot before install.
    await e.tick()
    e.block_gets=False
    await e.tick()
    start=len(e.responses)
    e.cpu[0]=Cpu(BASE)
    await e.tick();await e.tick();await e.tick()
    r=e.responses[start:][-1][2]
    assert r['status']==REPLAY and r['reason']==SNAP
    assert (await e.load(BASE))['data']==e.golden(BASE)
    await e.idle()


@cocotb.test()
async def s0_store_word_conflict(dut):
    e=await env(dut)
    await e.load(BASE)
    await e.until(lambda: not int(dut.full_line_busy_o.value) and not int(dut.internal_busy_o.value))
    await e.tick();await e.tick()
    start=len(e.responses)
    e.cpu[0]=Cpu(BASE,sta=True,ident=1)
    await e.tick()
    e.cpu[0]=Cpu(BASE,ident=2)
    await e.tick();await e.tick();await e.tick()
    r=next(r for _,_,r in e.responses[start:] if r['ident']==2)
    assert r['status']==REPLAY and r['reason']==CONFLICT
    assert (await e.load(BASE))['data']==e.golden(BASE)
    await e.idle()


@cocotb.test()
async def rfo_issue_reserve_drop_and_same_line_drop(dut):
    e=await env(dut)
    assert e.n==4 and e.rfo==1
    e.block_gets=True
    assert (await e.issue(Cpu(BASE,sta=True)))[0]['status']==OK
    await e.until(lambda: len(e.sent)==1)
    assert e.events[-1][1:3]==('get',GETM)
    # Same line has an MSHR: no second RFO and no instruction waiter.
    assert (await e.issue(Cpu(BASE,sta=True)))[0]['status']==OK
    assert int(dut.mon_ms_valid.value).bit_count()==1
    assert (await e.issue(Cpu(BASE+64,head=False)))[0]['status']==MISS
    await e.until(lambda: len(e.sent)==2)
    # Only two slots free: an RFO needs 2+reserve=3.
    assert (await e.issue(Cpu(BASE+128,sta=True)))[0]['status']==OK
    assert int(dut.mon_ms_valid.value).bit_count()==2
    e.block_gets=False
    await e.idle()
    await e.store(BASE,0x1234)
    assert (await e.load(BASE))['data']==0x1234
    await e.idle()


@cocotb.test()
async def cancellation_keeps_plru_and_mshr(dut):
    e=await env(dut)
    await e.load(BASE)
    await e.idle()
    original=int(dut.mon_plru.value)
    # Test each pipeline cancellation boundary, for both a hit and a miss.
    for addr in (BASE,BASE+64):
        for stage in range(3):
            await e.until(lambda: not int(dut.full_line_busy_o.value))
            await e.tick();await e.tick()
            before=len(e.responses);gets=sum(x[1]=='get' for x in e.events)
            e.cpu[0]=Cpu(addr,branch=1)
            for t in range(3):
                dut.flush_i.value=int(t==stage)
                await e.tick()
            dut.flush_i.value=0
            await e.tick()
            assert len(e.responses)==before
            assert int(dut.mon_plru.value)==original and int(dut.mon_ms_valid.value)==0
            assert sum(x[1]=='get' for x in e.events)==gets
    await e.idle()


@cocotb.test()
async def wb_capacity_full_wait_contract(dut):
    """Spec 5.4 says WB capacity failure is MSHR_FULL; 6.1 needs mshr_free.

    Both writeback slots retain unacknowledged Puts after the associated MSHRs
    have installed and freed. Releasing B/PutAck cannot create an MSHR event.
    This test keeps the frozen reason and event requirements explicit.
    """
    e=await env(dut)
    for k in range(e.ways):
        await e.load(BASE+k*e.sets*64)
    e.block_putacks=True
    for k in range(2):
        r=await e.load(BASE+(e.ways+k)*e.sets*64)
        assert r['status']==OK
    assert int(dut.mon_ms_valid.value)==0
    assert int(dut.mon_wb_valid.value)==3
    r=(await e.issue(Cpu(BASE+(e.ways+2)*e.sets*64)))[0]
    dut._log.info('WB_FULL witness cycle=%d status=%d reason=%d MSHR_busy=%d WB_busy=%d',
                 e.cycle,r['status'],r['reason'],int(dut.mon_ms_valid.value),int(dut.mon_wb_valid.value))
    assert r['status']==REPLAY and r['reason']==FULL, 'spec 5.4 requires MSHR_FULL for full victim WB slots'
    # Model the spec 6.1 waiter: only an mshr_free event can make it replayable.
    start=len(e.wakes)
    e.block_putacks=False
    await e.until(lambda: int(dut.mon_wb_valid.value)==0)
    for _ in range(40):
        await e.tick()
    dut._log.info('WB_FULL release wake_events=%s MSHR_busy=%d WB_busy=%d',
                 e.wakes[start:],int(dut.mon_ms_valid.value),int(dut.mon_wb_valid.value))
    assert any(w['free'] for _,w in e.wakes[start:]), 'spec 6.1 waiter never wakes: only wb_free arrived'
    assert (await e.load(BASE+(e.ways+2)*e.sets*64))['data']==e.golden(BASE+(e.ways+2)*e.sets*64)
    await e.idle()
