"""M2: behavioral L2 and CPU reservation/translation driver; no DUT state pokes."""
import os
import sys
from pathlib import Path
from collections import deque
from dataclasses import dataclass
from cocotb.triggers import Timer
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'l2_home'))
from mem_agents import pack, GETS, GETM, DATAS, DATAE, ACKE, PUTACK, MASK512

OK, MISS, REPLAY, ERROR = range(4)
NONE, OLDER_ADDR, OLDER_DATA, TLB, MSHR, FULL, WB_LINE, CONFLICT, SNAP, BANK, AD_ORDER = range(11)
BASE = 0x80000000


def unpack(value, fields):
    result = {}
    for name, width in reversed(fields):
        result[name] = value & ((1 << width) - 1)
        value >>= width
    assert value == 0
    return result


@dataclass
class Cpu:
    addr: int
    ident: int = 1
    lane: int = 0
    size: int = 3
    write: bool = False
    sta: bool = False
    signed: bool = False
    flw: bool = False
    head: bool = True
    blocked: bool = False
    forward: bool = False
    forward_data: int = 0
    translation_miss: bool = False
    exc: int = 0
    src: int = 0
    data: int = 0
    mask: int = 255
    branch: int = 0
    va: int = None
    rob: int = 1
    heu: bool = False
    check_only: bool = False
    split: bool = False
    raw: bool = False
    need_d: bool = False
    bytes: int = 0
    amo: int = 0


class CacheBench:
    def __init__(self, dut):
        self.d = dut
        self.cycle = 0
        self.n = int(os.environ.get('MSHRS', 4))
        self.sets = int(os.environ.get('SETS', 64))
        self.ways = int(os.environ.get('WAYS', 8))
        self.rfo = int(os.environ.get('RFO', 1))
        self.widths = None
        self.mem, self.gold, self.held = {}, {}, {}
        self.pending = deque()
        self.sent = {}
        self.rsp = None
        self.block_gets = False
        self.block_putacks = False
        self.latency = 6
        self.errors = set()
        self.shared = set()
        self.events = []
        self.responses = []
        self.wakes = []
        self.up = []
        self.snp = None
        self.snp_sent = False
        self.snp_dma_write = False
        self.dma_invalidations = []
        self.cpu = [None, None]
        self.prev_cpu = [None, None]
        self.st, self.ptw, self.ad = None, None, None
        self.st_responses, self.ptw_responses, self.ad_responses = [], [], []
        self.stalled = {}

    def initial(self, line):
        return int.from_bytes(bytes((line * 7 + i * 3 + 11) & 255 for i in range(64)), 'little')

    def golden(self, addr, size=8):
        line = addr >> 6
        return (self.gold.get(line, self.initial(line)) >> ((addr & 63) * 8)) & ((1 << (size * 8)) - 1)

    def req_bits(self, r):
        if r is None:
            return 0
        lq, sq, rob, branch = self.widths
        return pack((3, r.src), (56, r.addr), (64, r.addr if r.va is None else r.va), (2, r.size),
                    (1, int(r.write)), (1, int(r.sta)), (1, int(r.signed)), (1, int(r.flw)),
                    (1, int(r.head)), (1, int(r.heu)), (1, int(r.check_only)), (1, int(r.split)),
                    (1, int(r.raw)), (1, int(r.need_d)), (4, r.bytes), (2, 3), (8, 0), (3, 0),
                    (1, int(r.forward)), (1, int(r.blocked)), (1, int(r.translation_miss)),
                    (64, r.forward_data), (71, r.exc), (64, r.data), (8, r.mask), (4, r.amo),
                    (lq, r.ident & ((1 << lq) - 1)), (8, 1), (sq, r.ident & ((1 << sq) - 1)),
                    (rob, r.rob), (branch, r.branch))

    def resp_fields(self, raw):
        lq, sq, _, _ = self.widths
        return unpack(raw, [('valid', 1), ('src', 3), ('status', 3), ('reason', 4), ('mshr', 2),
                            ('ident', lq), ('gen', 8), ('sq', sq), ('data', 64), ('sc_fail', 1), ('need_d', 1), ('io', 1), ('head', 1), ('pa', 56), ('exc', 71)])

    async def reset(self):
        d = self.d
        inputs = ('cpu_valid','cpu0','cpu1','s1_cpu0','s1_cpu1','rob_head_i','flush_i',
                  'resolution_valid_i','resolution_mispredict_i','resolution_tag_i','st_req_valid_i',
                  'st_req_i','ptw_req_valid_i','ptw_req_i','pte_ad_req_valid_i','pte_ad_req_i',
                  'cur_epoch_i','pmp_i','l2_req_ready_i','l2_resp_valid_i',
                  'l2_resp_i','rsp_up_ready_i','snp_valid_i','snp_i')
        for name in inputs:
            getattr(d, name).value = 0
        d.context_valid_i.value = 0
        d.test_priv_i.value = 3
        d.rsv_clear_i.value = 0
        d.pmp_i.value = (0x1f << 54) | 0x1fffffff
        d.rst.value = 1
        for _ in range(3):
            d.clk.value = 0
            await Timer(5, unit='ns')
            d.clk.value = 1
            await Timer(5, unit='ns')
        d.clk.value = 0
        d.rst.value = 0
        await Timer(1, unit='ns')
        v = int(d.widths.value)
        self.widths = [(v >> x) & 255 for x in (24, 16, 8, 0)]
        await self.until(lambda: int(d.init_done.value), self.sets + 10)

    async def until(self, condition, limit=1000):
        for _ in range(limit):
            if condition():
                return
            await self.tick()
        assert False, f'cycle={self.cycle} watchdog; events={self.events[-32:]}'

    async def tick(self):
        d = self.d
        d.clk.value = 0
        d.cpu_valid.value = sum((r is not None) << p for p, r in enumerate(self.cpu))
        for p in range(2):
            getattr(d, 'cpu' + str(p)).value = self.req_bits(self.cpu[p])
            getattr(d, 's1_cpu' + str(p)).value = self.req_bits(self.prev_cpu[p])
        for name, r in (('st', self.st), ('ptw', self.ptw)):
            getattr(d, name + '_req_valid_i').value = int(r is not None)
            getattr(d, name + '_req_i').value = self.req_bits(r)
        d.pte_ad_req_valid_i.value = int(self.ad is not None)
        if self.ad:
            d.pte_ad_req_i.value = pack(*zip((56, 64, 1, 1, 8), self.ad))
        d.l2_req_ready_i.value = int(getattr(self, 'request_ready', True))
        d.rsp_up_ready_i.value = 1
        if self.rsp is None:
            for t in list(self.pending):
                due, op, tid, err, data, line = t
                if due <= self.cycle and not (self.block_gets if op != PUTACK else self.block_putacks):
                    self.pending.remove(t)
                    self.rsp = t
                    break
        d.l2_resp_valid_i.value = int(self.rsp is not None)
        if self.rsp:
            _, op, tid, err, data, _ = self.rsp
            d.l2_resp_i.value = pack((3, op), (2, tid), (1, err), (512, data))
        d.snp_valid_i.value = int(self.snp is not None and not self.snp_sent)
        if self.snp:
            op, owner, line = self.snp
            d.snp_i.value = pack((1, op), (1, owner), (1, int(self.snp_dma_write)), (26, line))
        await Timer(5, unit='ns')
        v = {name: int(getattr(d, name).value) for name in (
            'cpu_ready','resp0','resp1','st_req_ready_o','st_resp_o','ptw_req_ready_o','ptw_resp_o',
            'pte_ad_req_ready_o','pte_ad_resp_o','wake_o','l2_req_valid_o','l2_req_o','l2_req_ready_i',
            'l2_resp_ready_o','rsp_up_valid_o','rsp_up_o','snp_ready_o','full_line_busy_o',
            'internal_busy_o','idle_o','fatal_o','mon_ms_valid','mon_plru',
            'dma_invalidate_o','dma_line_o')}
        dma_before = self.state(v['dma_line_o'] << 6) if v['dma_invalidate_o'] else None
        assert v['fatal_o'] == 0
        for p, r in enumerate(self.cpu):
            if r:
                assert v['cpu_ready'] >> p & 1, 'test driver violated IS reservation'
        for p in range(2):
            r = self.resp_fields(v['resp' + str(p)])
            if r['valid']:
                self.responses.append((self.cycle, p, r))
        for key, dest in (('st_resp_o', self.st_responses), ('ptw_resp_o', self.ptw_responses)):
            r = self.resp_fields(v[key])
            if r['valid']:
                dest.append((self.cycle, r))
        if v['pte_ad_resp_o'] & 8:
            self.ad_responses.append((self.cycle, v['pte_ad_resp_o']))
        w = v['wake_o']
        if w:
            self.wakes.append((self.cycle, unpack(w, [('valid',1),('mshr',2),('err',1),('free',1),('wb_free',1)])))
        for channel, valid, raw in (('req', v['l2_req_valid_o'], v['l2_req_o']), ('up', v['rsp_up_valid_o'], v['rsp_up_o'])):
            # Consume only handshakes; the PTE suite also stalls REQ.
            if not valid or (channel == 'req' and not v['l2_req_ready_i']):
                continue
            if channel == 'req':
                q = unpack(raw, [('op',2),('line',26),('tid',2),('mask',64),('data',512)])
                op,line,tid=q['op'],q['line'],q['tid']
                assert op in (GETS, GETM) and tid not in self.sent
                assert len(self.sent) < self.n
                assert self.held.get(line) != 'X', 'Get from existing exclusive owner'
                rspop = ACKE if op == GETM and self.held.get(line) == 'S' else DATAS if line in self.shared and op == GETS else DATAE
                self.sent[tid] = line
                err = int(line in self.errors)
                data = self.mem.get(line, self.initial(line))
                self.pending.append((self.cycle + self.latency, rspop, tid, err, data, line))
                self.events.append((self.cycle, 'get', op, line, tid))
            else:
                q = unpack(raw, [('op',2),('dirty',1),('line',26),('tid',2),('data',512)])
                op,line,tid=q['op'],q['line'],q['tid']
                self.up.append((self.cycle, q))
                self.events.append((self.cycle, 'up', op, line, q['dirty']))
                if q['dirty']:
                    assert self.held.get(line) == 'X'
                    assert q['data'] == self.gold.get(line,self.initial(line)), f'dirty payload corrupted {line:x}'
                    self.mem[line] = q['data']
                if op == 0:
                    assert line in self.held, 'Put without directory permission'
                    self.held.pop(line)
                    self.pending.append((self.cycle+7,PUTACK,tid,0,0,line))
                else:
                    assert self.snp and self.snp_sent
                    assert line == self.snp[2] and op == (1 if self.snp[0] == 0 else 2)
                    if op == 1:
                        self.held.pop(line, None)
                    elif line in self.held:
                        self.held[line] = 'S'
                    self.snp = None
                    self.snp_sent = False
        if self.rsp and v['l2_resp_ready_o']:
            _,op,tid,err,data,line=self.rsp
            if op != PUTACK:
                assert self.sent.pop(tid) == line
                if not err:
                    self.held[line] = 'S' if op == DATAS else 'X'
            self.events.append((self.cycle,'grant',op,line,tid,err))
            self.rsp = None
        if self.snp and not self.snp_sent and v['snp_ready_o']:
            self.snp_sent = True
            self.events.append((self.cycle,'snp',*self.snp))
        if self.st and v['st_req_ready_o']:
            self.st = None
        if self.ptw and v['ptw_req_ready_o']:
            self.ptw = None
        if self.ad and v['pte_ad_req_ready_o']:
            self.ad = None
        self.prev_cpu = list(self.cpu)
        self.cpu = [None, None]
        d.clk.value = 1
        await Timer(5, unit='ns')
        self.cycle += 1
        if v['dma_invalidate_o']:
            line = v['dma_line_o']
            self.dma_invalidations.append((self.cycle - 1, line, dma_before))
            assert self.state(line << 6) == 0, 'DMA broadcast did not coincide with tag becoming I'
        return v

    async def issue(self, *requests):
        # Reserve at IS, then carry two bubbles to S0, matching the actual LSU.
        await self.until(lambda: not int(self.d.full_line_busy_o.value) and not int(self.d.internal_busy_o.value))
        await self.tick()
        await self.tick()
        before = len(self.responses)
        for r in requests:
            self.cpu[r.lane] = r
        await self.tick()
        await self.tick()
        await self.tick()
        answers = self.responses[before:]
        assert len(answers) == len(requests), f'S2 missing response: {answers}'
        return [next(a[2] for a in answers if a[1] == r.lane) for r in requests]

    async def load(self, addr, **kwargs):
        for _ in range(100):
            r = (await self.issue(Cpu(addr, **kwargs)))[0]
            if r['status'] in (OK, ERROR):
                return r
            if r['status'] == MISS:
                tid = r['mshr']
                start = len(self.wakes)
                await self.until(lambda: any(w['valid'] and w['mshr'] == tid for _,w in self.wakes[start:]))
            elif r['reason'] == WB_LINE:
                await self.until(lambda: not self.block_putacks and int(self.d.idle_o.value))
            elif r['reason'] == FULL:
                start = len(self.wakes)
                await self.until(lambda: any(w['free'] for _,w in self.wakes[start:]))
        assert False, 'load replay watchdog'

    async def store(self, addr, data, mask=255, ident=1):
        for _ in range(100):
            start = len(self.st_responses)
            self.st = Cpu(addr, write=True, src=1, data=data, mask=mask, ident=ident)
            await self.until(lambda: len(self.st_responses)>start)
            r = self.st_responses[-1][1]
            if r['status'] == OK:
                line=addr>>6;old=self.gold.get(line,self.initial(line))
                for i in range(8):
                    if mask>>i&1:
                        shift=((addr&63)+i)*8
                        old=(old&~(255<<shift))|(((data>>(i*8))&255)<<shift)
                self.gold[line]=old
                return r
            if r['status'] == ERROR:
                return r
            if r['status'] == MISS:
                tid = r['mshr'];wake_start=len(self.wakes)
                await self.until(lambda: any(w['valid'] and w['mshr']==tid for _,w in self.wakes[wake_start:]))
            else:
                await self.tick()
        assert False,'store replay watchdog'

    async def probe(self, addr, down=False):
        assert self.snp is None
        line=addr>>6
        self.snp=(int(down), int(self.held.get(line)=='X'), line)
        start=len(self.up)
        await self.until(lambda: self.snp is None)
        return self.up[start:][-1][1]

    def state(self, addr):
        states=int(self.d.mon_state.value);addrs=int(self.d.mon_addr.value);line=addr>>6
        return next(((states>>(2*k))&3 for k in range(self.sets*self.ways)
                     if (states>>(2*k))&3 and (addrs>>(26*k))&((1<<26)-1)==line), 0)

    async def idle(self):
        await self.until(lambda: int(self.d.idle_o.value) and not self.pending and self.rsp is None and not self.sent and self.snp is None)
