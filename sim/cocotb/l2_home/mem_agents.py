"""Independent golden RAM, AXI RAM, L1D proxy and link/directory monitor.

Breeze a304cc2 supplies the mechanism: independent backing/architectural memories,
permission tracking from handshakes, nonblocking probe answers and a watchdog.
The O3 protocol has 64-byte lines, 2-bit transaction IDs and no I directory.
"""
import os
import random
from collections import deque
from dataclasses import dataclass

from cocotb.triggers import Timer

GETS, GETM, READ = 0, 1, 2
PUT, INVACK, DOWNACK = 0, 1, 2
DATAS, DATAE, ACKE, PUTACK, READDATA = range(5)
MASK512 = (1 << 512) - 1


def pack(*fields):
    value = 0
    for width, field in fields:
        assert 0 <= field < 1 << width
        value = (value << width) | field
    return value


def req(op, line, tid):
    return pack((2, op), (26, line), (2, tid), (64, 0), (512, 0))


def up(op, dirty, line, tid, data):
    return pack((2, op), (1, int(dirty)), (26, line), (2, tid), (512, data))


def response(value):
    return value >> 515, (value >> 513) & 3, (value >> 512) & 1, value & MASK512


@dataclass
class Txn:
    op: int
    line: int
    tid: int
    start: int
    error: bool = False
    accepted: bool = False
    result: tuple = None


class Bench:
    def __init__(self, dut, seed=1):
        self.d = dut
        self.rng = random.Random(seed)
        self.seed = seed
        self.cycle = 0
        self.sets = int(os.environ.get('SETS', 2))
        self.ways = int(os.environ.get('WAYS', 2))
        self.slots = int(os.environ.get('SLOTS', 2))
        self.arch, self.ram, self.history = {}, {}, {}
        self.copies, self.held = {}, {}
        self.present = [None, None]
        self.out = [{}, {}]
        self.puts = {}
        self.upq = deque()
        self.probe = None
        self.readq = {}
        self.rhold = None
        self.awq, self.wq, self.bq = deque(), deque(), deque()
        self.bhold = None
        self.errors = set()
        self.block_r = False
        self.probe_delay = 0
        self.backpressure = False
        self.trace = deque(maxlen=32)
        self.events = []
        self.reads, self.writes = [], []
        self.stalled = {}
        self.i_script = deque()
        self.i_done = 0
        self.slot_full = 0

    def initial(self, line):
        return int.from_bytes(bytes(((line * 17 + i * 29 + self.seed) & 255) for i in range(64)), 'little')

    def golden(self, line):
        return self.arch.get(line, self.initial(line))

    def backing(self, line):
        return self.ram.get(line, self.initial(line))

    def note(self, *args):
        self.trace.append((self.cycle, *args))
        self.events.append((self.cycle, *args))

    def check(self, condition, message):
        assert condition, f'cycle {self.cycle}: {message}; recent={list(self.trace)}'

    def store(self, line, offset, size, value):
        state, data = self.copies[line]
        self.check(state in ('E', 'M'), f'store without exclusive permission {line:x}')
        self.check(data == self.golden(line), 'proxy diverged from golden')
        mask = ((1 << (8 * size)) - 1) << (8 * offset)
        data = (data & ~mask) | ((value << (8 * offset)) & mask)
        self.copies[line] = ('M', data)
        self.arch[line] = data
        self.history.setdefault(line, []).append((self.cycle, data))
        self.note('store', line)

    def submit(self, client, op, line, tid=None, error=False):
        self.check(self.present[client] is None, 'REQ already presented')
        if tid is None:
            tid = next(i for i in range(4) if i not in self.out[client])
        self.check(tid not in self.out[client], 'transaction ID reused')
        self.check(len(self.out[client]) < 4, 'Get/Read credit exceeded')
        t = Txn(op, line, tid, self.cycle, error)
        self.present[client] = t
        return t

    async def acquire(self, line, write=False, error=False):
        await self.until(lambda: not self.line_busy(line))
        state = self.copies.get(line, ('I', 0))[0]
        if state in ('E', 'M') or (state == 'S' and not write):
            return None
        t = self.submit(0, GETM if write else GETS, line, error=error)
        await self.until(lambda: t.result is not None)
        return t

    async def read(self, line, error=False):
        await self.until(lambda: self.present[1] is None)
        t = self.submit(1, READ, line, error=error)
        await self.until(lambda: t.result is not None)
        return t

    def evict(self, line, tid=0):
        state, data = self.copies[line]
        self.check(tid not in self.puts, 'Put credit reused')
        self.puts[tid] = (line, False)
        self.upq.append((PUT, state == 'M', line, tid, data))

    def line_busy(self, line):
        return (self.probe is not None and self.probe[2] == line) or any(
            t.line == line for t in self.out[0].values()) or any(p[0] == line for p in self.puts.values())

    async def until(self, predicate, limit=5000):
        for _ in range(limit):
            if predicate():
                return
            await self.tick()
        self.check(False, f'watchdog; out={self.out}; puts={self.puts}; probe={self.probe}; reads={self.readq}')

    async def reset(self):
        for name in ('l1d_req_valid_i', 'l1i_req_valid_i', 'dma_req_valid_i', 'dma_req_i',
                     'l1d_req_i', 'l1i_req_i', 'rsp_up_valid_i', 'rsp_up_i', 'snp_ready_i',
                     'm_axi_awready', 'm_axi_wready', 'm_axi_bvalid', 'm_axi_bid', 'm_axi_bresp',
                     'm_axi_arready', 'm_axi_rvalid', 'm_axi_rid', 'm_axi_rdata', 'm_axi_rresp', 'm_axi_rlast'):
            getattr(self.d, name).value = 0
        for client in ('l1d', 'l1i', 'dma'):
            getattr(self.d, client + '_resp_ready_i').value = 1
        self.d.rst.value = 1
        for _ in range(3):
            self.d.clk.value = 0
            await Timer(5, unit='ns')
            self.d.clk.value = 1
            await Timer(5, unit='ns')
        self.d.clk.value = 0
        self.d.rst.value = 0
        await self.until(lambda: int(self.d.init_done.value), limit=self.sets + 10)

    def chance(self):
        return not self.backpressure or self.rng.random() < .7

    async def tick(self):
        d = self.d
        d.clk.value = 0
        # The I client runs independently, with at most four transactions.
        if self.i_script and self.present[1] is None and len(self.out[1]) < 4:
            self.submit(1, READ, self.i_script.popleft())
        for c, name in enumerate(('l1d', 'l1i')):
            t = self.present[c]
            getattr(d, name + '_req_valid_i').value = int(t is not None)
            if t:
                getattr(d, name + '_req_i').value = req(t.op, t.line, t.tid)
        if self.probe and self.cycle >= self.probe[3] and not self.upq:
            op, owner, line, due = self.probe
            # A probe may wait for the line's grant or PutAck, never for REQ ready.
            busy = any(t.line == line for t in self.out[0].values()) or any(p[0] == line for p in self.puts.values())
            if not busy:
                state, data = self.copies.get(line, ('I', 0))
                self.check(state not in ('E', 'M') or owner, 'owner probe bit missing')
                self.check(state != 'S' or not owner, 'owner bit on sharer')
                self.upq.append((INVACK if op == 0 else DOWNACK, state == 'M', line, 0, data))
        u = self.upq[0] if self.upq else None
        d.rsp_up_valid_i.value = int(u is not None)
        if u:
            d.rsp_up_i.value = up(*u)
        d.snp_ready_i.value = int(self.probe is None and self.chance())
        d.m_axi_arready.value = int(self.chance())
        d.m_axi_awready.value = int(self.chance())
        d.m_axi_wready.value = int(self.chance())
        if self.rhold is None and not self.block_r and self.chance():
            eligible = [k for k, t in self.readq.items() if t[3] <= self.cycle]
            if eligible:
                rid = self.rng.choice(eligible)
                line, data, beat, due = self.readq[rid]
                self.rhold = (rid, (data >> (128 * beat)) & ((1 << 128) - 1),
                              2 if line in self.errors and beat == 1 else 0, int(beat == 3))
        d.m_axi_rvalid.value = int(self.rhold is not None)
        if self.rhold:
            for name, value in zip(('rid', 'rdata', 'rresp', 'rlast'), self.rhold):
                getattr(d, 'm_axi_' + name).value = value
        if self.bhold is None and self.bq and self.bq[0][0] <= self.cycle:
            self.bhold = self.bq.popleft()[1]
        d.m_axi_bvalid.value = int(self.bhold is not None)
        d.m_axi_bid.value = self.bhold or 0
        d.m_axi_bresp.value = 0
        await Timer(5, unit='ns')
        names = ('l1d_resp_valid_o', 'l1d_resp_o', 'l1i_resp_valid_o', 'l1i_resp_o',
                 'l1d_req_ready_o', 'l1i_req_ready_o', 'rsp_up_ready_o', 'snp_valid_o',
                 'snp_ready_i', 'snp_o', 'm_axi_arvalid', 'm_axi_arready', 'm_axi_araddr',
                 'm_axi_arid', 'm_axi_arlen', 'm_axi_arsize', 'm_axi_arburst',
                 'm_axi_awvalid', 'm_axi_awready', 'm_axi_awaddr', 'm_axi_awid',
                 'm_axi_awlen', 'm_axi_awsize', 'm_axi_awburst', 'm_axi_wvalid', 'm_axi_wready',
                 'm_axi_wdata', 'm_axi_wstrb', 'm_axi_wlast', 'm_axi_rready', 'm_axi_bready',
                 'fatal_o', 'mon_slot_full')
        v = {n: int(getattr(d, n).value) for n in names}
        self.check(v['fatal_o'] == 0, 'unexpected fatal event')
        self.slot_full += v['mon_slot_full']
        for prefix, ready, fields in (
            ('snp', 'snp_ready_i', ('snp_o',)),
            ('m_axi_ar', 'm_axi_arready', ('m_axi_arid', 'm_axi_araddr', 'm_axi_arlen', 'm_axi_arsize', 'm_axi_arburst')),
            ('m_axi_aw', 'm_axi_awready', ('m_axi_awid', 'm_axi_awaddr', 'm_axi_awlen', 'm_axi_awsize', 'm_axi_awburst')),
            ('m_axi_w', 'm_axi_wready', ('m_axi_wdata', 'm_axi_wstrb', 'm_axi_wlast'))):
            valid = v[prefix + ('_valid_o' if prefix == 'snp' else 'valid')]
            bits = tuple(v[f] for f in fields)
            if prefix in self.stalled:
                self.check(valid and bits == self.stalled[prefix], f'{prefix} changed while stalled')
            if valid and not v[ready]:
                self.stalled[prefix] = bits
            else:
                self.stalled.pop(prefix, None)
        # Process old response permissions before same-edge answers and new requests.
        for c, name in enumerate(('l1d', 'l1i')):
            if v[name + '_resp_valid_o']:
                op, tid, err, data = response(v[name + '_resp_o'])
                self.note('response', c, op, tid)
                if c == 0 and op == PUTACK:
                    self.check(tid in self.puts and self.puts[tid][1], 'unmatched PutAck')
                    del self.puts[tid]
                    continue
                self.check(tid in self.out[c], f'unmatched response c={c}, id={tid}')
                t = self.out[c].pop(tid)
                self.check(bool(err) == t.error, f'error bit line {t.line:x}')
                if c == 0:
                    st = self.held.get(t.line, 'I')
                    self.check(op in (DATAS, DATAE, ACKE), 'invalid Get response')
                    self.check(t.op != GETM or op != DATAS, 'GetM granted shared')
                    if not err:
                        if op == ACKE:
                            self.check(t.op == GETM and st == 'S', 'AckE without shared permission')
                            data = self.copies[t.line][1]
                        else:
                            self.check(st == 'I', 'grant while holding a copy (SWMR)')
                        self.check(data == self.golden(t.line), f'Get data mismatch {t.line:x}: {data:x} != {self.golden(t.line):x}')
                        self.held[t.line] = 'S' if op == DATAS else 'X'
                        self.copies[t.line] = ('S' if op == DATAS else 'E', data)
                else:
                    self.check(op == READDATA, 'I received a permission grant')
                    if not err:
                        hist = self.history.get(t.line, [])
                        prior = [x for cycle, x in hist if cycle <= t.start]
                        legal = [prior[-1] if prior else self.initial(t.line)] + [x for cycle, x in hist if t.start < cycle <= self.cycle]
                        self.check(data in legal, f'Read data mismatch {t.line:x}: {data:x}')
                        self.check(self.held.get(t.line) != 'X', 'ReadData before owner DownAck')
                    self.i_done += 1
                t.result = (op, err, data)
        if u and v['rsp_up_ready_o']:
            self.upq.popleft()
            op, dirty, line, tid, data = u
            self.note('up', op, line, dirty)
            st = self.held.get(line, 'I')
            self.check(not dirty or st == 'X', 'dirty answer without owner (SWMR)')
            if op == PUT:
                self.check(st != 'I', 'Put without held permission')
                self.held.pop(line)
                self.copies.pop(line)
                self.puts[tid] = (line, True)
            else:
                self.check(self.probe is not None and self.probe[2] == line, 'answer without probe')
                self.check(op == (INVACK if self.probe[0] == 0 else DOWNACK), 'wrong probe answer')
                if op == INVACK:
                    self.held.pop(line, None)
                    self.copies.pop(line, None)
                elif st != 'I':
                    self.held[line] = 'S'
                    self.copies[line] = ('S', data)
                self.probe = None
        if v['snp_valid_o'] and v['snp_ready_i']:
            raw = v['snp_o']
            line, owner, op = raw & ((1 << 26) - 1), (raw >> 26) & 1, raw >> 27
            self.check(self.probe is None, 'more than one probe in flight')
            self.check(op == 0 or owner, 'Down without owner')
            self.probe = (op, owner, line, self.cycle + 1 + self.probe_delay)
            self.note('probe', op, owner, line)
        for c, name in enumerate(('l1d', 'l1i')):
            t = self.present[c]
            if t and v[name + '_req_ready_o']:
                self.check(t.tid not in self.out[c], 'duplicate accepted ID')
                if c == 0:
                    st = self.held.get(t.line, 'I')
                    self.check(st == 'I' if t.op == GETS else st != 'X', 'illegal permission request')
                    self.check(not any(p[0] == t.line for p in self.puts.values()), 'Get before PutAck')
                t.accepted = True
                self.out[c][t.tid] = t
                self.present[c] = None
                self.note('req', c, t.op, t.line, t.tid)
        if v['m_axi_arvalid'] and v['m_axi_arready']:
            rid, addr = v['m_axi_arid'], v['m_axi_araddr']
            self.check(rid not in self.readq, 'AXI read ID reused')
            self.check(addr % 64 == 0 and (v['m_axi_arlen'], v['m_axi_arsize'], v['m_axi_arburst']) == (3, 4, 1), 'AXI read burst shape')
            self.readq[rid] = (addr >> 6, self.backing(addr >> 6), 0, self.cycle + self.rng.randrange(1, 13))
            self.reads.append(addr >> 6)
        if self.rhold and v['m_axi_rready']:
            rid, _, _, last = self.rhold
            line, data, beat, due = self.readq[rid]
            if last:
                del self.readq[rid]
            else:
                self.readq[rid] = (line, data, beat + 1, due)
            self.rhold = None
        if v['m_axi_awvalid'] and v['m_axi_awready']:
            self.check((v['m_axi_awlen'], v['m_axi_awsize'], v['m_axi_awburst']) == (3, 4, 1), 'AXI write burst shape')
            self.awq.append((v['m_axi_awid'], v['m_axi_awaddr'] >> 6))
        if v['m_axi_wvalid'] and v['m_axi_wready']:
            self.check(v['m_axi_wstrb'] == 0xffff, 'partial whole-line write')
            self.wq.append((v['m_axi_wdata'], v['m_axi_wlast']))
        if self.awq and len(self.wq) >= 4:
            wid, line = self.awq.popleft()
            beats = [self.wq.popleft() for _ in range(4)]
            self.check([last for _, last in beats] == [0, 0, 0, 1], 'AXI WLAST shape')
            data = sum(value << (128 * i) for i, (value, _) in enumerate(beats))
            self.ram[line] = data
            self.writes.append((line, data))
            self.note('axi-write', line)
            self.bq.append((self.cycle + self.rng.randrange(2, 15), wid))
        if self.bhold is not None and v['m_axi_bready']:
            self.bhold = None
        d.clk.value = 1
        await Timer(5, unit='ns')
        self.cycle += 1
        # Directory structural invariant every cycle, exact correspondence at idle.
        valid, sharer, states = int(d.mon_valid.value), int(d.mon_sharer.value), int(d.mon_state.value)
        addrs = int(d.mon_addr.value)
        seen = set()
        for k in range(self.sets * self.ways):
            state = (states >> (k * 2)) & 3
            share = (sharer >> k) & 1
            self.check((state == 0) == (not share), 'directory state/sharer inconsistency')
            if valid >> k & 1:
                line = (addrs >> (k * 26)) & ((1 << 26) - 1)
                self.check(line not in seen, 'duplicate valid tag')
                seen.add(line)

    def idle(self):
        return (not any(self.present) and not any(self.out) and not self.puts and not self.probe
                and not self.upq and not self.readq and not self.rhold and not self.awq and not self.wq
                and not self.bq and self.bhold is None and not self.i_script
                and not int(self.d.mon_slot_busy.value))

    async def finish(self):
        await self.until(self.idle)
        for line in sorted(self.arch):
            t = await self.read(line)
            self.check(t.result[2] == self.golden(line), 'final golden readback')
        await self.until(self.idle)
        states, addrs = int(self.d.mon_state.value), int(self.d.mon_addr.value)
        valid = int(self.d.mon_valid.value)
        directory = {}
        for k in range(self.sets * self.ways):
            if valid >> k & 1:
                st = (states >> (k * 2)) & 3
                if st:
                    directory[(addrs >> (k * 26)) & ((1 << 26) - 1)] = 'S' if st == 1 else 'X'
        self.check(directory == self.held, f'exact directory mismatch {directory} != {self.held}')
        self.d._log.info('M1 cycles=%d AXI_reads=%d AXI_writes=%d I_reads=%d', self.cycle, len(self.reads), len(self.writes), self.i_done)
