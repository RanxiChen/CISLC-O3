"""hpm_counters directed tests; expected values follow L7a spec 6.3 / U11 / U21."""
import cocotb
from cocotb.triggers import Timer

RW, RS, RC = 1, 2, 3
MCYCLE, MINSTRET, MINHIBIT = 0xB00, 0xB02, 0x320
MASK64 = (1 << 64) - 1


def hpmc(n):
    return 0xB00 + n


def hpme(n):
    return 0x320 + n


async def settle():
    await Timer(1, unit="ns")


class Tb:
    def __init__(self, d):
        self.d = d
        self.fe = {}
        self.be = {}

    async def reset(self):
        d = self.d
        for n in ["clk", "req_valid_i", "write_i", "op_i", "addr_i", "data_i",
                  "retired_i", "fe_perf_i", "be_perf_i"]:
            getattr(d, n).value = 0
        d.priv_i.value = 3
        d.rst.value = 1
        await self.edge()
        d.rst.value = 0
        await settle()
        self.few = int(d.fe_w_o.value)
        self.bew = int(d.be_w_o.value)
        self.fenum = int(d.fe_num_o.value)
        self.benum = int(d.be_num_o.value)
        self.nhpm = int(d.num_hpm_o.value)
        assert self.nhpm == 8

    async def edge(self):
        d = self.d
        d.clk.value = 0
        await settle()
        d.clk.value = 1
        await settle()
        d.clk.value = 0
        await settle()

    def drive_perf(self, fe=None, be=None):
        """fe/be: {event_number: increment}; element k occupies bits [k*W +: W]."""
        self.fe = fe or {}
        self.be = be or {}
        v = 0
        for k, inc in self.fe.items():
            assert inc < (1 << self.few)
            v |= inc << (k * self.few)
        self.d.fe_perf_i.value = v
        v = 0
        for k, inc in self.be.items():
            assert inc < (1 << self.bew)
            v |= inc << (k * self.bew)
        self.d.be_perf_i.value = v

    def drive_all_max(self):
        fe = {k: (1 << self.few) - 1 for k in range(self.fenum)}
        be = {k: (1 << self.bew) - 1 for k in range(self.benum)}
        self.drive_perf(fe, be)

    async def peek(self, addr):
        """Combinational read with no clock edge (reads have no side effects)."""
        d = self.d
        d.req_valid_i.value = 1
        d.addr_i.value = addr
        d.op_i.value = RS
        d.data_i.value = 0
        d.write_i.value = 0
        await settle()
        r = int(d.read_o.value), int(d.illegal_o.value)
        d.req_valid_i.value = 0
        await settle()
        return r

    async def access(self, addr, op=RW, data=0, write=True):
        """Present one request for one cycle; returns (rdata, illegal, write_o) before the edge."""
        d = self.d
        d.req_valid_i.value = 1
        d.addr_i.value = addr
        d.op_i.value = op
        d.data_i.value = data & MASK64
        d.write_i.value = int(write)
        await settle()
        r = int(d.read_o.value), int(d.illegal_o.value), int(d.write_o.value)
        await self.edge()
        d.req_valid_i.value = 0
        d.write_i.value = 0
        await settle()
        return r

    async def cycles(self, n):
        for _ in range(n):
            await self.edge()


async def setup(d):
    tb = Tb(d)
    await tb.reset()
    return tb


async def clear_counters(tb):
    """Inhibit all, zero all, resume (U23 initialisation order)."""
    await tb.access(MINHIBIT, RW, MASK64)
    for n in range(3, 3 + tb.nhpm):
        await tb.access(hpmc(n), RW, 0)
    await tb.access(MCYCLE, RW, 0)
    await tb.access(MINSTRET, RW, 0)
    await tb.access(MINHIBIT, RW, 0)


@cocotb.test()
async def reset_values_zero(d):
    tb = await setup(d)
    for a in [MCYCLE, MINSTRET, MINHIBIT] + [hpmc(n) for n in range(3, 11)] + [hpme(n) for n in range(3, 11)]:
        v, ill = await tb.peek(a)
        assert ill == 0 and v == 0, (hex(a), v, ill)


@cocotb.test()
async def mcycle_and_minstret_count(d):
    tb = await setup(d)
    await tb.cycles(10)
    assert (await tb.peek(MCYCLE))[0] == 10
    total = 0
    for r in [1, 4, 0, 3, 2]:
        d.retired_i.value = r
        total += r
        await tb.edge()
    d.retired_i.value = 0
    assert (await tb.peek(MINSTRET))[0] == total


@cocotb.test()
async def event_select_fe_and_be(d):
    """Source 1 = FE, source 2 = BE; increments >1 add their full value."""
    tb = await setup(d)
    sel = {3: 0x0102, 4: 0x0201, 5: 0x0115, 6: 0x0133, 7: 0x0225, 8: 0x0101}
    for n, s in sel.items():
        await tb.access(hpme(n), RW, s)
    await clear_counters(tb)
    fe = {0x02: 3, 0x15: 1, 0x33: 2, 0x01: 0, 0x03: 5, 0x0F: 7}
    be = {0x01: 2, 0x25: 1, 0x02: 3}
    tb.drive_perf(fe, be)
    await tb.cycles(6)
    tb.drive_perf()
    exp = {3: 3 * 6, 4: 2 * 6, 5: 1 * 6, 6: 2 * 6, 7: 1 * 6, 8: 0, 9: 0, 10: 0}
    for n, e in exp.items():
        assert (await tb.peek(hpmc(n)))[0] == e, (n, e, (await tb.peek(hpmc(n)))[0])


    # T08c allocates BE 0x26..0x29. Check their full increments explicitly.
    assert tb.benum == 0x2a
    for event in range(0x26,0x2a):
        await tb.access(hpme(3),RW,0x0200|event)
        await clear_counters(tb)
        tb.drive_perf(be={event:3})
        await tb.cycles(4);tb.drive_perf()
        assert (await tb.peek(hpmc(3)))[0] == 12, hex(event)


@cocotb.test()
async def varying_increment_accumulates(d):
    tb = await setup(d)
    await tb.access(hpme(3), RW, 0x0110)
    await clear_counters(tb)
    total = 0
    for inc in [1, 0, (1 << tb.few) - 1, 2, 5]:
        tb.drive_perf({0x10: inc})
        total += inc
        await tb.edge()
    tb.drive_perf()
    assert (await tb.peek(hpmc(3)))[0] == total


@cocotb.test()
async def disabled_and_unknown_events_do_not_count(d):
    """Event 0, FE numbering holes (0x16..0x1F), beyond-last numbers, unknown sources."""
    tb = await setup(d)
    sel = [0x0000, 0x0100, 0x0116, 0x011F, 0x0134, 0x0200 | tb.benum, 0x0301, 0x0001]
    for i, s in enumerate(sel):
        await tb.access(hpme(3 + i), RW, s)
    await clear_counters(tb)
    tb.drive_all_max()
    await tb.cycles(5)
    tb.drive_perf()
    for i, s in enumerate(sel):
        v = (await tb.peek(hpmc(3 + i)))[0]
        assert v == 0, (hex(s), v)


@cocotb.test()
async def mcountinhibit_bits_pause_own_counter(d):
    tb = await setup(d)
    await tb.access(hpme(3), RW, 0x0101)
    await tb.access(hpme(4), RW, 0x0101)
    await clear_counters(tb)
    tb.drive_perf({0x01: 1})
    d.retired_i.value = 1
    # CY: mcycle frozen, minstret / HPM keep going.
    await tb.access(MINHIBIT, RW, 0x1)
    c0, i0, h0 = [(await tb.peek(a))[0] for a in (MCYCLE, MINSTRET, hpmc(3))]
    await tb.cycles(4)
    assert (await tb.peek(MCYCLE))[0] == c0
    assert (await tb.peek(MINSTRET))[0] == i0 + 4
    assert (await tb.peek(hpmc(3)))[0] == h0 + 4
    # IR: minstret frozen, mcycle resumes.
    await tb.access(MINHIBIT, RW, 0x4)
    c0, i0 = [(await tb.peek(a))[0] for a in (MCYCLE, MINSTRET)]
    await tb.cycles(4)
    assert (await tb.peek(MINSTRET))[0] == i0
    assert (await tb.peek(MCYCLE))[0] == c0 + 4
    # HPM3 only: hpm3 frozen, hpm4 counts.
    await tb.access(MINHIBIT, RW, 0x8)
    h3, h4 = [(await tb.peek(a))[0] for a in (hpmc(3), hpmc(4))]
    await tb.cycles(4)
    assert (await tb.peek(hpmc(3)))[0] == h3
    assert (await tb.peek(hpmc(4)))[0] == h4 + 4
    tb.drive_perf()
    d.retired_i.value = 0


@cocotb.test()
async def mcountinhibit_writable_mask(d):
    tb = await setup(d)
    rd, ill, _ = await tb.access(MINHIBIT, RW, MASK64)
    assert ill == 0
    exp = 0x1 | 0x4 | (((1 << tb.nhpm) - 1) << 3)
    assert (await tb.peek(MINHIBIT))[0] == exp
    await tb.access(MINHIBIT, RC, 0x8)
    assert (await tb.peek(MINHIBIT))[0] == exp & ~0x8


@cocotb.test()
async def counter_write_overrides_only_written_counter(d):
    """U11: written counter takes the value and drops its increment; others still count."""
    tb = await setup(d)
    await tb.access(hpme(3), RW, 0x0101)
    await tb.access(hpme(4), RW, 0x0101)
    await clear_counters(tb)
    tb.drive_perf({0x01: 2})
    d.retired_i.value = 3
    await tb.cycles(2)
    c, i, h3, h4 = [(await tb.peek(a))[0] for a in (MCYCLE, MINSTRET, hpmc(3), hpmc(4))]
    await tb.access(hpmc(3), RW, 100)
    assert (await tb.peek(hpmc(3)))[0] == 100
    assert (await tb.peek(hpmc(4)))[0] == h4 + 2
    assert (await tb.peek(MCYCLE))[0] == c + 1
    assert (await tb.peek(MINSTRET))[0] == i + 3
    await tb.access(MCYCLE, RW, 1000)
    assert (await tb.peek(MCYCLE))[0] == 1000
    assert (await tb.peek(hpmc(3)))[0] == 102
    await tb.access(MINSTRET, RW, 77)
    assert (await tb.peek(MINSTRET))[0] == 77
    assert (await tb.peek(MCYCLE))[0] == 1001
    tb.drive_perf()
    d.retired_i.value = 0


@cocotb.test()
async def config_writes_take_effect_next_cycle(d):
    """U11: mhpmevent / mcountinhibit writes leave this cycle on the old configuration."""
    tb = await setup(d)
    await clear_counters(tb)
    tb.drive_perf({0x01: 3})
    # Edge N: event 0 -> UBTB_LOOKUP; this edge still uses event 0.
    await tb.access(hpme(3), RW, 0x0101)
    assert (await tb.peek(hpmc(3)))[0] == 0
    await tb.edge()
    assert (await tb.peek(hpmc(3)))[0] == 3
    # Set inhibit bit3 at edge N: N still counts, then frozen.
    await tb.access(MINHIBIT, RW, 0x8)
    assert (await tb.peek(hpmc(3)))[0] == 6
    await tb.cycles(2)
    assert (await tb.peek(hpmc(3)))[0] == 6
    # Clear inhibit at edge N: N still frozen, then counts.
    await tb.access(MINHIBIT, RW, 0x0)
    assert (await tb.peek(hpmc(3)))[0] == 6
    await tb.edge()
    assert (await tb.peek(hpmc(3)))[0] == 9
    tb.drive_perf()


@cocotb.test()
async def read_returns_old_value_and_rmw(d):
    tb = await setup(d)
    await tb.access(hpmc(5), RW, 0x50)
    rd, ill, wo = await tb.access(hpmc(5), RS, 0x0F)
    assert (rd, ill, wo) == (0x50, 0, 0x5F)
    assert (await tb.peek(hpmc(5)))[0] == 0x5F
    rd, ill, wo = await tb.access(hpmc(5), RC, 0x0F)
    assert (rd, wo) == (0x5F, 0x50)
    await tb.access(MCYCLE, RW, 500)
    rd, _, _ = await tb.access(MCYCLE, RW, 7)
    assert rd == 500 + 0, rd  # written last edge, read returns pre-edge value
    assert (await tb.peek(MCYCLE))[0] == 7


@cocotb.test()
async def mhpmevent_warl_selector_and_sscofpmf(d):
    tb = await setup(d)
    for n in range(3, 11):
        _, ill, _ = await tb.access(hpme(n), RW, MASK64)
        assert ill == 0
        v = (await tb.peek(hpme(n)))[0]
        assert v == 0xF00000000000FFFF, (n, hex(v))


@cocotb.test()
async def unimplemented_11_to_31_read_zero_write_ignored(d):
    """U21: mhpmcounter/mhpmevent 11..31 read 0, writes ignored and legal."""
    tb = await setup(d)
    for n in range(11, 32):
        for a in (hpmc(n), hpme(n)):
            _, ill, _ = await tb.access(a, RW, MASK64)
            assert ill == 0, hex(a)
            v, ill = await tb.peek(a)
            assert (v, ill) == (0, 0), (hex(a), v, ill)
        v, ill = await tb.peek(0xC00 + n)
        assert (v, ill) == (0, 0), (hex(0xC00 + n), v, ill)


@cocotb.test()
async def readonly_aliases_match_and_writes_illegal(d):
    tb = await setup(d)
    await tb.access(hpme(3), RW, 0x0101)
    await tb.access(MINHIBIT, RW, MASK64)
    await tb.access(MCYCLE, RW, 0x1111)
    await tb.access(MINSTRET, RW, 0x2222)
    for n in range(3, 11):
        await tb.access(hpmc(n), RW, 0x100 + n)
    for n in [0, 2] + list(range(3, 11)):
        m, mi = await tb.peek(0xB00 + n)
        u, ui = await tb.peek(0xC00 + n)
        assert (mi, ui) == (0, 0) and m == u, (n, m, u)
    for n in [0, 2] + list(range(3, 32)):
        for op in (RW, RS, RC):
            _, ill, _ = await tb.access(0xC00 + n, op, 1)
            assert ill == 1, (hex(0xC00 + n), op)
    # Illegal writes leave state untouched (everything is inhibited).
    assert (await tb.peek(MCYCLE))[0] == 0x1111
    assert (await tb.peek(MINSTRET))[0] == 0x2222
    for n in range(3, 11):
        assert (await tb.peek(hpmc(n)))[0] == 0x100 + n


@cocotb.test()
async def counter_wraps_at_64_bits(d):
    tb = await setup(d)
    await tb.access(hpme(3), RW, 0x0101)
    tb.drive_perf({0x01: 2})
    await tb.access(hpmc(3), RW, MASK64)
    await tb.edge()
    tb.drive_perf()
    assert (await tb.peek(hpmc(3)))[0] == 1


@cocotb.test()
async def switch_live_sources_and_rmw_with_events(d):
    tb = await setup(d)
    await tb.access(hpme(3), RW, 0x0101)
    await clear_counters(tb)
    tb.drive_perf({1: 3}, {1: 5})
    await tb.access(hpme(3), RW, 0x0201)
    assert (await tb.peek(hpmc(3)))[0] == 3  # write edge still FE
    await tb.edge()
    assert (await tb.peek(hpmc(3)))[0] == 8  # next edge BE
    rd, ill, wo = await tb.access(hpmc(3), RS, 0x20)
    assert (rd, ill, wo) == (8, 0, 0x28)
    assert (await tb.peek(hpmc(3)))[0] == 0x28  # drop BE increment only here
    rd, ill, wo = await tb.access(hpmc(3), RC, 8)
    assert (rd, ill, wo) == (0x28, 0, 0x20)
    # write_en=0 is a read, even with a nonzero operand and events on that edge.
    rd, ill, _ = await tb.access(hpmc(3), RS, MASK64, write=False)
    assert (rd, ill) == (0x20, 0)
    assert (await tb.peek(hpmc(3)))[0] == 0x25


@cocotb.test()
async def invalid_request_and_ignored_rmw_write_values(d):
    tb = await setup(d)
    await tb.access(hpme(10), RW, 0x0101)
    await clear_counters(tb)
    tb.drive_perf({1: 2})
    d.req_valid_i.value = 0
    d.write_i.value = 1
    d.addr_i.value = hpmc(10)
    d.data_i.value = MASK64
    d.op_i.value = RW
    await tb.cycles(3)
    assert (await tb.peek(hpmc(10)))[0] == 6
    for n in range(11, 32):
        for addr in (hpmc(n), hpme(n)):
            for op in (RW, RS, RC):
                rd, ill, wo = await tb.access(addr, op, MASK64)
                assert (rd, ill, wo) == (0, 0, 0), (hex(addr), op, rd, ill, wo)
    assert (await tb.peek(hpmc(10)))[0] == 6 + 21 * 2 * 3 * 2


@cocotb.test()
async def inhibit_every_hpm_and_reset_live_state(d):
    tb = await setup(d)
    for n in range(3, 11):
        await tb.access(hpme(n), RW, 0x0101)
    await clear_counters(tb)
    tb.drive_perf({1: 2})
    for frozen in range(3, 11):
        await tb.access(MINHIBIT, RW, 1 << frozen)
        before = [(await tb.peek(hpmc(n)))[0] for n in range(3, 11)]
        await tb.cycles(2)
        after = [(await tb.peek(hpmc(n)))[0] for n in range(3, 11)]
        assert after == [v + (0 if n == frozen else 4) for n, v in zip(range(3, 11), before)]
    d.rst.value = 1
    d.req_valid_i.value = 1
    d.addr_i.value = hpmc(3)
    d.write_i.value = 1
    d.data_i.value = MASK64
    await tb.edge()
    d.rst.value = 0
    d.req_valid_i.value = 0
    d.write_i.value = 0
    for n in range(3, 11):
        assert (await tb.peek(hpmc(n)))[0] == 0
        assert (await tb.peek(hpme(n)))[0] == 0
    assert (await tb.peek(MINHIBIT))[0] == 0

@cocotb.test()
async def sscofpmf_privilege_filter_and_overflow(d):
    tb=await setup(d)
    for priv,bit in ((3,62),(1,61),(0,60)):
        d.priv_i.value=priv
        await tb.access(hpme(3),RW,(1<<bit)|0x0101)
        await tb.access(hpmc(3),RW,100)
        tb.drive_perf({1:1});await tb.cycles(3)
        assert (await tb.peek(hpmc(3)))[0]==100
        tb.drive_perf();await tb.access(hpme(3),RW,0x0101)
        tb.drive_perf({1:1});await tb.cycles(2);tb.drive_perf()
        assert (await tb.peek(hpmc(3)))[0]==102
    await tb.access(hpmc(3),RW,MASK64)
    tb.drive_perf({1:1});await settle();assert int(d.overflow_o.value)==1
    await tb.edge();tb.drive_perf()
    assert (await tb.peek(hpmc(3)))[0]==0
    assert (await tb.peek(hpme(3)))[0]==(1<<63)|0x0101
    assert int(d.ovf_o.value)==8
    await tb.access(hpmc(3),RW,MASK64);tb.drive_perf({1:1})
    await settle();assert int(d.overflow_o.value)==0 # OF suppresses repeated LCOFIP requests
    await tb.edge();tb.drive_perf()


@cocotb.test()
async def overflow_uses_software_of_and_old_configuration(d):
    tb=await setup(d)
    # Old OF / software OF cover clear-on-wrap, suppress-on-write and sticky OF.
    for old_of,software_of in ((0,0),(1,0),(0,1),(1,1)):
        tb.drive_perf()
        await tb.access(hpme(3),RW,(old_of<<63)|0x0101)
        await tb.access(hpmc(3),RW,MASK64)
        tb.drive_perf({1:1})
        d.req_valid_i.value=1;d.write_i.value=1;d.addr_i.value=hpme(3)
        d.op_i.value=RW;d.data_i.value=(software_of<<63)|(1<<62)|0x0202
        await settle()
        assert int(d.overflow_o.value)==(not software_of),(old_of,software_of)
        await tb.edge();tb.drive_perf();d.req_valid_i.value=0;d.write_i.value=0
        assert (await tb.peek(hpmc(3)))[0]==0  # old FE event counts despite new MINH
        assert (await tb.peek(hpme(3)))[0]==(1<<63)|(1<<62)|0x0202
        assert int(d.ovf_o.value)&8
    tb.drive_perf()
    await tb.access(hpme(3),RW,0x0101)
    await tb.access(hpmc(3),RW,MASK64)
    tb.drive_perf({1:1})
    d.req_valid_i.value=1;d.write_i.value=1;d.addr_i.value=hpmc(3)
    d.op_i.value=RW;d.data_i.value=99
    await settle();assert int(d.overflow_o.value)==0
    await tb.edge();tb.drive_perf();d.req_valid_i.value=0;d.write_i.value=0
    assert (await tb.peek(hpmc(3)))[0]==99
    assert (await tb.peek(hpme(3)))[0]==0x0101
