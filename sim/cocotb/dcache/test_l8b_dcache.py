"""N2 independent atomic byte oracle and head/probe/permission contracts."""
import cocotb
from l8a_agents import CacheBench, Cpu, BASE, OK, MISS, REPLAY, ERROR, GETM, MASK512

LR, SC, SWAP, ADD, XOR, AND, OR, MIN, MAX, MINU, MAXU = range(11)
MASK64 = (1 << 64) - 1


def signed(value, bits):
    return value - (1 << bits) if value >> (bits - 1) else value


def result_value(old, data, op, bits):
    mask = (1 << bits) - 1
    a, b = old & mask, data & mask
    if op == SWAP: value = b
    elif op == ADD: value = a + b
    elif op == XOR: value = a ^ b
    elif op == AND: value = a & b
    elif op == OR: value = a | b
    elif op == MIN: value = a if signed(a, bits) < signed(b, bits) else b
    elif op == MAX: value = a if signed(a, bits) > signed(b, bits) else b
    elif op == MINU: value = min(a, b)
    elif op == MAXU: value = max(a, b)
    else: value = b  # SC writes the supplied bytes.
    return value & mask


def write_gold(e, addr, value, size=8):
    line, offset = addr >> 6, addr & 63
    data = bytearray(e.gold.get(line, e.initial(line)).to_bytes(64, 'little'))
    data[offset:offset + size] = value.to_bytes(size, 'little')
    e.gold[line] = int.from_bytes(data, 'little')


def atomic_req(addr, op, data=0, size=3, **kwargs):
    return Cpu(addr, src=2, lane=1, heu=True, write=op != LR,
               signed=True, amo=op, data=data, size=size, **kwargs)


async def attempt(e, request):
    await e.until(lambda: not int(e.d.full_line_busy_o.value) and not int(e.d.internal_busy_o.value))
    await e.tick(); await e.tick()
    before = len(e.responses)
    e.cpu[request.lane] = request
    for _ in range(12):
        await e.tick()
        answers = e.responses[before:]
        if answers:
            assert len(answers) == 1 and answers[0][1] == request.lane
            return answers[0][2]
    assert False, 'head request response watchdog'


async def atomic(e, addr, op, data=0, size=3, **kwargs):
    old = e.golden(addr, 1 << size)
    request = atomic_req(addr, op, data, size, **kwargs)
    for _ in range(100):
        r = await attempt(e, request)
        if r['status'] == OK:
            if op == LR:
                assert r['data'] == (signed(old, 32) & MASK64 if size == 2 else old)
            elif op == SC:
                assert r['data'] == int(bool(r['sc_fail']))
                if not r['sc_fail']: write_gold(e, addr, data & ((1 << (8 << size)) - 1), 1 << size)
            else:
                assert r['data'] == (signed(old, 32) & MASK64 if size == 2 else old)
                write_gold(e, addr, result_value(old, data, op, 8 << size), 1 << size)
            return r
        if r['status'] == ERROR: return r
        if r['status'] == MISS:
            # A completed wake is visible in the same tick as the response too.
            start = len(e.wakes)
            await e.until(lambda: any(w['valid'] and w['mshr'] == r['mshr'] for _, w in e.wakes[start:]))
        else:
            assert r['status'] == REPLAY
            await e.tick()
    assert False, 'atomic replay watchdog'


async def env(d):
    e = CacheBench(d)
    await e.reset()
    return e


async def arithmetic_coverage(d, op):
    e = await env(d)
    pairs = [(0x12345678f0000000, 0x876543217fffffff),
             (0xabcdef0180000000, 0xffffffff7fffffff),
             (0x8000000000000000, 0x7fffffffffffffff), (0, 0), (MASK64, MASK64)]
    for size, offset in ((2, 0), (2, 4), (3, 0)):
        for old_word, operand in pairs:
            await e.store(BASE, old_word)
            assert (await atomic(e, BASE + offset, op, operand, size))['status'] == OK
            old = (old_word >> (8 * offset)) & ((1 << (8 << size)) - 1)
            expected = bytearray(old_word.to_bytes(8, 'little'))
            expected[offset:offset + (1 << size)] = result_value(old, operand, op, 8 << size).to_bytes(1 << size, 'little')
            assert (await e.load(BASE))['data'] == int.from_bytes(expected, 'little')
    await e.idle()


for _op, _name in enumerate(('swap', 'add', 'xor', 'and', 'or', 'min', 'max', 'minu', 'maxu'), SWAP):
    def _make(op, name):
        async def test(d): await arithmetic_coverage(d, op)
        test.__name__ = 'amo_' + name + '_w_offsets_and_d_boundary_oracle'
        test.__qualname__ = test.__name__
        return cocotb.test()(test)
    globals()['amo_' + _name] = _make(_op, _name)


@cocotb.test()
async def amo_cold_getm_shared_upgrade_and_failed_refill_no_write(d):
    e = await env(d)
    old = e.golden(BASE)
    r = await atomic(e, BASE, ADD, 17)
    assert r['status'] == OK and r['data'] == old
    assert [x[2] for x in e.events if x[1] == 'get'] == [GETM]
    await e.probe(BASE, down=True)
    before = len(e.events)
    assert (await atomic(e, BASE, XOR, MASK64))['status'] == OK
    assert any(x[1] == 'grant' and x[2] == 2 for x in e.events[before:])
    addr = BASE + 64
    e.errors.add(addr >> 6)
    miss = await attempt(e, atomic_req(addr, ADD, 123))
    assert miss['status'] == MISS
    await e.until(lambda: any(w['valid'] and w['err'] and w['mshr'] == miss['mshr'] for _, w in e.wakes))
    assert e.state(addr) == 0 and e.golden(addr) == e.initial(addr >> 6) & MASK64
    # LSU propagates the refill failure on the retry, as in the existing M2 case.
    err = (1 << 70) | (7 << 64) | addr
    assert (await attempt(e, atomic_req(addr, ADD, 123, exc=err)))['status'] == ERROR
    await e.idle()


@cocotb.test()
async def amo_rmw_probe_waits_and_receives_updated_dirty_line(d):
    e = await env(d)
    await e.load(BASE)
    old = e.golden(BASE)
    r = atomic_req(BASE, ADD, 0x11223344)
    await e.tick(); await e.tick()
    e.cpu[1] = r
    await e.tick(); await e.tick()
    assert int(d.mon_ps_alloc.value)
    e.snp = (0, 1, BASE >> 6)
    await e.tick()
    assert int(d.mon_ps_valid.value) and int(d.mon_ps_write.value) and int(d.irreversible_o.value)
    assert int(d.mon_probe_hold.value) and not int(d.mon_probe_read.value)
    decision_cycle = e.cycle
    write_gold(e, BASE, (old + 0x11223344) & MASK64)
    await e.tick()
    assert e.responses[-1][2]['data'] == old
    await e.until(lambda: e.snp is None)
    q = e.up[-1][1]
    assert e.up[-1][0] > decision_cycle and q['dirty'] and q['data'] == e.gold[BASE >> 6]
    await e.idle()


@cocotb.test()
async def amo_wait_getm_allows_shared_inv_then_install_hold_until_retry(d):
    e = await env(d)
    e.shared.add(BASE >> 6)
    await e.load(BASE)
    e.block_gets = True
    r = await attempt(e, atomic_req(BASE, ADD, 5))
    assert r['status'] == MISS
    await e.until(lambda: e.sent)
    q = await e.probe(BASE)
    assert q['op'] == 1 and not q['dirty']
    assert e.pending and not int(d.mon_atomic_hold.value)
    # The external writer invalidated our former S copy. The eventual grant
    # must carry DataE, rather than the AckE queued before that contention.
    e.pending = type(e.pending)((due, 1, tid, err, data, line)
                               for due, op, tid, err, data, line in e.pending)
    e.block_gets = False
    await e.until(lambda: int(d.mon_atomic_hold.value))
    e.snp = (0, 1, BASE >> 6)
    await e.tick()
    assert e.snp_sent and int(d.mon_probe_hold.value) and not int(d.mon_probe_read.value)
    assert (await atomic(e, BASE, ADD, 5))['status'] == OK
    await e.until(lambda: e.snp is None)
    assert e.up[-1][1]['data'] == e.gold[BASE >> 6]
    await e.idle()


@cocotb.test()
async def lr_getm_exact_pair_sc_once_and_permission_precedes_failure(d):
    e = await env(d)
    assert (await atomic(e, BASE, LR))['status'] == OK
    assert [x[2] for x in e.events if x[1] == 'get'] == [GETM]
    assert int(d.mon_rsv_valid.value) and int(d.mon_rsv_window.value)
    assert not (await atomic(e, BASE, SC, 0xdeadbeef))['sc_fail']
    before = len(e.events)
    assert (await atomic(e, BASE, SC, 3))['sc_fail']
    assert len(e.events) == before and (await e.load(BASE))['data'] == 0xdeadbeef
    for addr, size in ((BASE + 8, 3), (BASE, 2)):
        await atomic(e, BASE, LR)
        before = len(e.events)
        assert (await atomic(e, addr, SC, 2, size))['sc_fail']
        assert len(e.events) == before and not int(d.mon_rsv_valid.value)
    r = await atomic(e, 0x02001000, SC, 1)
    assert r['status'] == ERROR and (r['exc'] >> 64) & 63 == 7
    await e.idle()


@cocotb.test()
async def reservation_clear_table_and_down_timer_branch_do_not_clear(d):
    e = await env(d)
    await atomic(e, BASE, LR)
    for _ in range(85): await e.tick()
    assert int(d.mon_rsv_valid.value) and not int(d.mon_rsv_window.value)
    await e.probe(BASE, down=True)
    assert int(d.mon_rsv_valid.value) and e.state(BASE) == 1
    assert not (await atomic(e, BASE, SC, 55))['sc_fail']
    await atomic(e, BASE, LR)
    await e.load(BASE)
    await e.store(BASE + 64, 1)
    d.resolution_valid_i.value = 1; d.resolution_mispredict_i.value = 1
    await e.tick()
    d.resolution_valid_i.value = 0; d.resolution_mispredict_i.value = 0
    assert int(d.mon_rsv_valid.value)
    await e.store(BASE + 8, 2)
    assert not int(d.mon_rsv_valid.value)
    await atomic(e, BASE, LR)
    await atomic(e, BASE + 8, ADD, 1)
    assert not int(d.mon_rsv_valid.value)
    await atomic(e, BASE, LR)
    original = e.golden(BASE + 16)
    e.ad = (BASE + 16, original, 1, 1, 0)
    await e.until(lambda: e.ad_responses)
    write_gold(e, BASE + 16, original | 0xc0)
    assert e.ad_responses[-1][1] == 12 and not int(d.mon_rsv_valid.value)
    for event in ('trap', 'xret', 'sfence', 'satp'):
        await atomic(e, BASE, LR)
        d.rsv_clear_i.value = 1
        await e.tick(); d.rsv_clear_i.value = 0
        assert not int(d.mon_rsv_valid.value), event
    await atomic(e, BASE, LR)
    for _ in range(85): await e.tick()
    await e.probe(BASE)
    assert not int(d.mon_rsv_valid.value)
    await atomic(e, BASE, LR)
    for way in range(1, e.ways + 1): await e.load(BASE + way * e.sets * 64)
    await e.idle()
    assert e.state(BASE) == 0 and not int(d.mon_rsv_valid.value)


@cocotb.test()
async def lr_window_holds_inv_sc_success_then_latest_response_and_dma_broadcast(d):
    e = await env(d)
    await atomic(e, BASE, LR)
    e.snp = (0, 1, BASE >> 6); e.snp_dma_write = True
    for _ in range(12):
        v = await e.tick()
        assert int(d.mon_rsv_valid.value) and int(d.mon_probe_hold.value)
        assert not int(d.mon_probe_read.value) and not int(d.dma_invalidate_o.value)
    assert not (await atomic(e, BASE, SC, 0x8877665544332211))['sc_fail']
    assert not int(d.mon_rsv_valid.value)
    await e.until(lambda: e.snp is None)
    assert len(e.dma_invalidations) == 1
    cycle, line, previous_state = e.dma_invalidations[0]
    assert line == BASE >> 6 and previous_state == 3 and cycle <= e.up[-1][0]
    assert e.up[-1][1]['dirty'] and e.up[-1][1]['data'] == e.gold[BASE >> 6] and e.state(BASE) == 0
    await e.idle()


@cocotb.test()
async def io_fault_alignment_page_fault_and_pre_effect_cancel(d):
    e = await env(d)
    before = len(e.events)
    for write in (False, True):
        r = (await e.issue(Cpu(0x02001000, write=write, sta=write)))[0]
        assert r['status'] == REPLAY and r['reason'] == 11 and r['io']
        r = (await e.issue(Cpu(0x02001001, write=write, sta=write)))[0]
        assert r['status'] == ERROR and (r['exc'] >> 64) & 63 == (6 if write else 4)
    assert len(e.events) == before and not int(d.mon_ms_valid.value)
    for op, cause in ((LR, 5), (SC, 7), (ADD, 7)):
        r = await atomic(e, 0x02001000, op, 1)
        assert r['status'] == ERROR and (r['exc'] >> 64) & 63 == cause
        r = await atomic(e, BASE + 1, op, 1)
        assert r['status'] == ERROR and (r['exc'] >> 64) & 63 == (4 if op == LR else 6)
        va = 0x7000
        exc = (1 << 70) | ((13 if op == LR else 15) << 64) | va
        r = await atomic(e, BASE, op, 1, va=va, exc=exc)
        assert r['status'] == ERROR and r['exc'] == exc
    e.block_gets = True
    r = await attempt(e, atomic_req(BASE, ADD, 9))
    assert r['status'] == MISS
    d.flush_i.value = 1; await e.tick(); d.flush_i.value = 0
    e.block_gets = False
    for _ in range(50): await e.tick()
    assert not int(d.mon_rsv_valid.value) and e.golden(BASE) == e.initial(BASE >> 6) & MASK64
    assert (await e.load(BASE))['data'] == e.golden(BASE)
    await e.idle()


@cocotb.test()
async def permission_register_context_transition_allow_and_deny_cpu_and_ptw(d):
    e = await env(d)
    d.context_valid_i.value = 1
    # No PMP match permits M mode and denies S mode. Context change follows a
    # drained pipeline and flush, matching the core's serial CSR/trap contract.
    d.pmp_i.value = 0
    for priv, allow in ((3, True), (1, False), (3, True)):
        await e.idle()
        d.flush_i.value = 1; await e.tick(); d.flush_i.value = 0
        d.test_priv_i.value = priv
        r = await e.load(BASE)
        assert r['status'] == (OK if allow else ERROR)
        if not allow: assert (r['exc'] >> 64) & 63 == 5
    # PMP writes are serial too; check both directions immediately afterwards.
    d.test_priv_i.value = 1
    for state, allow in (((0x1f << 54) | 0x1fffffff, True), (0, False), ((0x1f << 54) | 0x1fffffff, True)):
        await e.idle()
        d.flush_i.value = 1; await e.tick(); d.flush_i.value = 0
        d.pmp_i.value = state
        r = await e.load(BASE)
        assert r['status'] == (OK if allow else ERROR)
        before = len(e.ptw_responses)
        e.ptw = Cpu(BASE, src=3)
        await e.until(lambda: len(e.ptw_responses) > before)
        assert e.ptw_responses[-1][1]['status'] == (OK if allow else ERROR)
    await e.idle()


@cocotb.test()
async def y11_pte_accessed_update_then_ordinary_load_actual_program_values(d):
    e = await env(d)
    addr, old = 0x80102038, 0x20040c07
    await e.store(addr, old)
    e.ptw = Cpu(addr, src=3)
    await e.until(lambda: e.ptw_responses)
    assert e.ptw_responses[-1][1]['status'] == OK and e.ptw_responses[-1][1]['data'] == old
    e.ad = (addr, old, 1, 0, 0)
    await e.until(lambda: e.ad_responses)
    assert e.ad_responses[-1][1] == 12
    write_gold(e, addr, old | 0x40)
    r = await e.load(addr)
    assert r['status'] == OK and r['data'] == old | 0x40
    assert r['data'] & 0xc0 == 0x40
    await e.idle()
