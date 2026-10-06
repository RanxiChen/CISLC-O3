"""Public-port integration: F1 -> arbiter -> selective FIFO/RQ kill -> CSR/HPM."""
import cocotb
from cocotb.triggers import Timer

NOP = 0x13
# jal x1,+64: target is the PC of this instruction plus 64.
JAL64 = 0x040000ef


class Bench:
    def __init__(self, d, head):
        self.d, self.head = d, head
        self.held = None
        self.totals = [0, 0, 0]

    async def step(self, *, count=0, fid=0, word0=NOP, word1=NOP, stall=0,
                   exec_id=None, exec_slot=0, target=0x9000, winner=None,
                   pd=0, done=0, done_id=0, rsv=0, resp=0, rq_id=0,
                   drain=0, rq_drain=0, csr=None, rst=0):
        d = self.d
        values = dict(clk_i=0, rst_i=rst, count_i=count, id_i=fid, head_i=self.head,
                      base_i=0x80001000, word0_i=word0, word1_i=word1, stall_i=stall,
                      deq_ready_i=drain, exec_valid_i=exec_id is not None,
                      exec_id_i=exec_id or 0, exec_slot_i=exec_slot, exec_target_i=target,
                      done_i=done, done_id_i=done_id, rsv_i=rsv, resp_i=resp,
                      rq_id_i=rq_id, rq_ready_i=rq_drain, csr_valid_i=csr is not None,
                      csr_write_i=csr is not None and len(csr) == 2,
                      csr_addr_i=csr[0] if csr else 0, csr_data_i=csr[1] if csr and len(csr) == 2 else 0)
        for name, value in values.items():
            getattr(d, name).value = value
        await Timer(1, unit='ns')
        if not rst:
            assert int(d.pd_valid_o.value) == pd
            assert int(d.kill_o.value) == int(winner is not None)
            assert int(d.busy_o.value) == int(self.held is not None)
            wanted = [int(winner is not None and winner[0] == 1),
                      int(winner is not None and winner[0] == 2), int(self.held is not None)]
            actual = [int(getattr(d, n).value) for n in ('pd_inc_o','exec_inc_o','recover_inc_o')]
            assert actual == wanted, (actual, wanted)
            self.totals = [a+b for a,b in zip(self.totals, wanted)]
            if winner:
                assert (int(d.winner_src_o.value), int(d.winner_id_o.value), int(d.target_o.value)) == winner
                assert int(d.f1_ready_o.value) == int(d.deq_valid_o.value) == int(d.rq_valid_o.value) == 0
        before = {n: int(getattr(d, n).value) for n in
                  ('mask_o','ids_o','slots_o','last_o','taken_o','next_o',
                   'rq_valid_o','rq_reserve_ready_o','rq_out_id_o','csr_read_o','f1_ready_o')}
        d.clk_i.value = 1
        await Timer(1, unit='ns')
        d.clk_i.value = 0
        if rst:
            self.held = None
            self.totals = [0, 0, 0]
        elif winner:
            self.held = winner
        elif self.held and done and done_id == self.held[1]:
            self.held = None
        return before

    async def init(self):
        await self.step(rst=1)
        await self.step(rst=1)
        for n, event in ((3, 0x0107), (4, 0x0108), (5, 0x010a)):
            await self.step(csr=(0x320+n, event))

    async def counters(self):
        for n, expected in zip((3,4,5), self.totals):
            observed = await self.step(csr=(0xb00+n,))
            assert observed['csr_read_o'] == expected, (n, observed['csr_read_o'], expected)

    def lanes(self, sample):
        d = self.d
        iw = len(d.ids_o)//len(d.mask_o)
        sw = len(d.slots_o)//len(d.mask_o)
        return [((sample['ids_o']>>(i*iw))&((1<<iw)-1),
                 (sample['slots_o']>>(i*sw))&((1<<sw)-1),
                 (sample['next_o']>>(i*64))&((1<<64)-1))
                for i in range(len(d.mask_o)) if sample['mask_o']>>i&1]


@cocotb.test()
async def predecode_winner_keeps_old_and_corrected_entries(d):
    for wrap in (False, True):
        depth = int(d.depth_o.value)
        iw = (depth-1).bit_length()
        old = depth-1 if wrap else 3
        current = 1<<iw if wrap else 4
        younger = current+1
        b = Bench(d, old)
        await b.init()
        await b.step(count=2, fid=old)
        await b.step(rsv=1, rq_id=old)
        for _ in range(4):
            await b.step(count=2, fid=current, word1=JAL64, stall=1)
        await b.step(count=2, fid=current, word1=JAL64)
        await b.step(count=2, fid=younger, word0=JAL64, resp=1, rq_id=old,
                     pd=1, winner=(1,current,0x80001044))
        s = await b.step()
        assert b.lanes(s) == [(old,0,0x80001004),(old,2,0x80001008),
                             (current,0,0x80001004),(current,2,0x80001044)]
        assert s['last_o'] == 0b1010 and s['taken_o'] == 0b1000
        assert s['rq_valid_o'] and s['rq_out_id_o'] == old  # response received on kill edge
        await b.step(done=1, done_id=younger)  # stale completion cannot release recovery
        await b.step(done=1, done_id=current)
        await b.step(drain=1, rq_drain=1)
        s = await b.step()
        assert s['mask_o'] == s['rq_valid_o'] == 0
        await b.counters()


@cocotb.test()
async def older_exec_beats_or_replaces_real_predecode(d):
    for replacement in (False, True):
        b = Bench(d, 7)
        await b.init()
        await b.step(count=2, fid=7)
        await b.step(rsv=1, rq_id=9)
        await b.step(count=2, fid=8, word1=JAL64)
        if replacement:
            await b.step(pd=1, winner=(1,8,0x80001044))
            await b.step(exec_id=7, exec_slot=0, target=0x9000,
                         winner=(2,7,0x9000), resp=1, rq_id=9)
        else:
            await b.step(pd=1, exec_id=7, exec_slot=0, target=0x9000,
                         winner=(2,7,0x9000), resp=1, rq_id=9)
        s = await b.step()
        assert b.lanes(s) == [(7,0,0x80001004)]
        assert s['rq_valid_o'] == 0 and s['rq_reserve_ready_o'] == 1
        await b.step(done=1, done_id=8)
        await b.step(done=1, done_id=7)
        await b.step(drain=1)
        assert (await b.step())['mask_o'] == 0
        await b.counters()
