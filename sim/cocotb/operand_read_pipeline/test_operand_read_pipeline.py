"""Independent transaction model for a pipelined, replaying operand scheduler.
Candidates are sorted in Python at priority admission, then checked against INT/FP
budgets and reserved per-FU capture capacity. This checks continuous issue and
slow-FU isolation as well as complete ownership, operands and cancellation.
"""
import os
import random
import cocotb
from cocotb.triggers import Timer


@cocotb.test()
async def ownership_operands_cancellation_and_continuous_issue(dut):
    seed = int(os.environ.get("TEST_SEED", "1"))
    rng = random.Random(seed)
    await Timer(1, unit="ns")
    cfg = {name: int(getattr(dut, name+"_o").value) for name in (
        "sources", "rob_entries", "preg_width", "mask_width", "rob_width", "int_ports",
        "mem_source_base", "mem_sources", "fp_source_base", "fp_ports", "fp_read_sets",
        "fp_store_base", "num_fma", "request_slots", "capture_slots")}
    n, rob_count, ports = cfg["sources"], cfg["rob_entries"], cfg["int_ports"]
    preg_w, mask_w, rob_w = cfg["preg_width"], cfg["mask_width"], cfg["rob_width"]
    mem_base, mem_count = cfg["mem_source_base"], cfg["mem_sources"]
    fp_base, fp_ports = cfg["fp_source_base"], cfg["fp_ports"]
    fp_sets, fp_store_base = cfg["fp_read_sets"], cfg["fp_store_base"]
    br_slot, mem_slots = fp_base-1, tuple(range(mem_base, mem_base+mem_count))
    requests = [[None]*cfg["request_slots"] for _ in range(n)]
    priority, reads, captures = None, [None, None], [[] for _ in range(n)]
    accepted, consumed, canceled, observed = set(), set(), set(), set()
    cycle = 0

    def pack(items, width):
        return sum(int(x) << (i*width) for i, x in enumerate(items))

    def unpack(name, width, count):
        bits = int(getattr(dut, name).value)
        return [(bits >> (i*width)) & ((1 << width)-1) for i in range(count)]

    async def step(valid=0, eligible=None, ready=None, delivery=None, reset=False,
                   flush=False, kill=False, correct=False, block=False, head=0,
                   masks=None, one_source=False):
        nonlocal requests, priority, reads, captures, cycle
        all_sources = (1 << n)-1
        eligible = all_sources if eligible is None else eligible
        ready = all_sources if ready is None else ready
        delivery = all_sources if delivery is None else delivery
        items = [dict(identity=cycle*n+i+1, mask=(masks or [0]*n)[i], rob=(head+i) % rob_count,
                      a=(i*3+1) % 64, b=(i*3+2) % 64, c=(i*3+3) % 64,
                      first=True if one_source else bool(rng.randrange(2)),
                      second=False if one_source else bool(rng.randrange(2)),
                      third=(i >= fp_base and bool(rng.randrange(2))),
                      fp_int=(i == n-1), store_fp=(i in mem_slots and bool(rng.randrange(2))))
                 for i in range(n)]
        dut.clk.value = 0
        for name, value in dict(rst=reset, flush_i=flush, block_i=block, kill_i=kill,
                                correct_i=correct, head_i=head, valid_i=valid,
                                pending_ready_i=eligible, read_ready_i=ready,
                                delivery_ready_i=delivery).items():
            getattr(dut, name).value = value
        for name, field, width in (("identity_i", "identity", 16), ("mask_i", "mask", mask_w),
                                   ("rob_i", "rob", rob_w), ("src1_i", "a", preg_w),
                                   ("src2_i", "b", preg_w), ("src3_i", "c", preg_w),
                                   ("need1_i", "first", 1), ("need2_i", "second", 1),
                                   ("need3_i", "third", 1), ("fp_int_i", "fp_int", 1),
                                   ("store_fp_i", "store_fp", 1)):
            getattr(dut, name).value = pack([x[field] for x in items], width)
        await Timer(2, unit="ns")
        active = not (reset or flush or block)

        def resolve(item):
            if item is None:
                return None
            if kill and item["mask"] & 1:
                canceled.add(item["identity"])
                return None
            return dict(item, mask=item["mask"] & ~1 if kill or correct else item["mask"])

        def resolve_packet(packet):
            if packet is None:
                return None
            owners = {i: x for i, item in packet["owners"].items() if (x := resolve(item)) is not None}
            return dict(packet, owners=owners) if owners else None

        rq = [[resolve(x) for x in q] for q in requests]
        pr, rd = resolve_packet(priority), [resolve_packet(x) for x in reads]
        cq = [[x for item in q if (x := resolve(item)) is not None] for q in captures]
        # Select the oldest unreserved source request, with physical-slot tie order.
        p, candidate_slots, free_slots = [None]*n, [None]*n, [None]*n
        for i in range(n):
            free_slots[i] = next((s for s, x in enumerate(requests[i]) if x is None), None)
            candidates = [s for s, x in enumerate(rq[i]) if x and not x["sent"]]
            if candidates:
                s = min(candidates, key=lambda s: ((rq[i][s]["rob"]-head) % rob_count, s))
                p[i], candidate_slots[i] = rq[i][s], s
        r = [rd[0]["owners"].get(i) if rd[0] else None for i in range(n)]
        c = [resolve(q[0]) if q else None for q in captures]
        takes = [bool(active and valid >> i & 1 and free_slots[i] is not None) for i in range(n)]
        grants = [bool(x and active and ready >> i & 1 and len(captures[i]) < cfg["capture_slots"])
                  for i, x in enumerate(r)]
        delivers = [bool(x and active and delivery >> i & 1) for i, x in enumerate(c)]
        offers = [i for i, x in enumerate(p) if x and active and eligible >> i & 1]
        rank_in = None
        if offers:
            rank_in = dict(owners={i: dict(p[i], slot=candidate_slots[i]) for i in offers},
                           order=sorted(offers, key=lambda i: ((p[i]["rob"]-head) % rob_count, i)))
        selected, allocation = set(), None
        if reads[1] is None and active and pr:
            port1, port2, bases = [0]*n, [0]*n, [0]*5
            addresses, fp_addresses = [0]*ports, [0]*fp_ports
            used, fp_used = 0, 0
            for i in pr["order"]:
                x = pr["owners"].get(i)
                if x is None:
                    continue
                reserved = sum(bool(packet and i in packet["owners"]) for packet in reads)
                if len(captures[i])+reserved >= cfg["capture_slots"]:
                    continue
                first = x["first"] and (i < fp_base or x["fp_int"])
                second = x["second"] and i < fp_base and not (i in mem_slots and x["store_fp"])
                demand = int(first)+int(second)
                if used+demand > ports or (i >= fp_base and fp_used == fp_sets):
                    continue
                selected.add(i)
                if first:
                    port1[i] = used;addresses[used] = x["a"];used += 1
                if second:
                    port2[i] = used;addresses[used] = x["b"];used += 1
                if i >= fp_base:
                    bases[i-fp_base] = fp_used*3
                    fp_addresses[fp_used*3:fp_used*3+3] = [x["a"], x["b"], x["c"]]
                    fp_used += 1
            for i in mem_slots:
                if i in selected:
                    fp_addresses[fp_store_base+i-mem_base] = pr["owners"][i]["b"]
            if selected:
                allocation = dict(owners={i: pr["owners"][i] for i in selected},
                                  maps=(port1, port2, bases, addresses, fp_addresses))
        context = f"seed={seed} cycle={cycle} selected={selected} grants={grants} delivers={delivers}"
        for name, expected in (("take_o", takes), ("grant_o", grants), ("delivery_grant_o", delivers),
                               ("pending_valid_o", [bool(x) for x in p]),
                               ("read_valid_o", [bool(x) for x in r]),
                               ("delivery_valid_o", [bool(x) for x in c])):
            assert int(getattr(dut, name).value) == pack(expected, 1), (context, name)
        for name, slots in (("pending_identity_o", p), ("read_identity_o", r), ("delivery_identity_o", c)):
            actual = unpack(name, 16, n)
            for i, x in enumerate(slots):
                if x:
                    assert actual[i] == x["identity"], (context, name, i, actual[i], x)
        for name, slots in (("read_mask_o", r), ("delivery_mask_o", c)):
            actual = unpack(name, mask_w, n)
            for i, x in enumerate(slots):
                if x:
                    assert actual[i] == x["mask"], (context, name, i)
        if rd[0]:
            for name, width, count, expected in zip(
                    ("port1_o", "port2_o", "fp_base_o", "int_addr_o", "fp_addr_o"),
                    (3, 3, 3, preg_w, preg_w), (n, n, 5, ports, fp_ports), rd[0]["maps"]):
                actual = unpack(name, width, count)
                assert actual == expected, (context, name, actual, expected)
        for operand, name in enumerate(("operand1_o", "operand2_o", "operand3_o")):
            actual = unpack(name, 64, n)
            for i, x in enumerate(c):
                if x:
                    assert actual[i] == x["values"][operand], (context, name, i, actual[i], x)
        for i, grant in enumerate(delivers):
            if grant:
                ident = c[i]["identity"]
                assert ident in accepted and ident not in consumed and ident not in canceled, (context, ident)
                consumed.add(ident)
        if any(grants): observed.add("read")
        if any(r) and not all(x is None or grants[i] for i, x in enumerate(r)): observed.add("hold")
        if kill: observed.add("kill")
        if correct: observed.add("resolve")
        if any(delivers[i] for i in range(fp_base, n)): observed.add("fp")
        if any(delivers[i] for i in mem_slots): observed.add("mem")
        if delivers[br_slot]: observed.add("branch")
        if reset or flush:
            canceled.update(accepted-consumed)
            requests = [[None]*cfg["request_slots"] for _ in range(n)]
            priority, reads, captures = None, [None, None], [[] for _ in range(n)]
        else:
            if active and pr:
                for i, x in pr["owners"].items():
                    s = x["slot"]
                    assert rq[i][s] and rq[i][s]["identity"] == x["identity"] and rq[i][s]["sent"], context
                    rq[i][s] = rq[i][s] if i in selected else dict(rq[i][s], sent=False)
            for i, grant in enumerate(grants):
                if grant:
                    slot = r[i]["slot"]
                    assert rq[i][slot] and rq[i][slot]["identity"] == r[i]["identity"], context
                    rq[i][slot] = None
            for i in offers:
                rq[i][candidate_slots[i]] = dict(rq[i][candidate_slots[i]], sent=True)
            for i, take in enumerate(takes):
                if take:
                    accepted.add(items[i]["identity"])
                    x = resolve(items[i])
                    rq[i][free_slots[i]] = dict(x, sent=False) if x else None
            # Operand capture is independent of delivery/FU readiness.
            for i in range(n):
                keep = []
                for slot, item in enumerate(captures[i]):
                    x = resolve(item)
                    if x and not (slot == 0 and delivers[i]):
                        keep.append(x)
                if grants[i]:
                    x = r[i]
                    value1 = (0x2000 if i >= fp_base and not x["fp_int"] else 0x1000)+x["a"] if x["first"] else 0
                    value2 = (0x2000 if i >= fp_base or x["store_fp"] else 0x1000)+x["b"] if x["second"] else 0
                    value3 = 0x2000+x["c"] if i >= fp_base and x["third"] else 0
                    keep.append(dict(x, values=(value1, value2, value3)))
                assert len(keep) <= cfg["capture_slots"], context
                cq[i] = keep
            if rd[0]:
                rd[0]["owners"] = {i: x for i, x in rd[0]["owners"].items() if not grants[i]}
                if not rd[0]["owners"]: rd[0] = None
            if rd[0] is None: rd = [rd[1], None]
            if allocation:
                assert rd[1] is None, context
                rd[0 if rd[0] is None else 1] = allocation
            requests, reads, captures = rq, rd, cq
            priority = rank_in if active else pr
        dut.clk.value = 1
        await Timer(2, unit="ns")
        cycle += 1
        return pack(takes, 1), pack(grants, 1), pack(delivers, 1)

    await step(reset=True)
    for _ in range(cfg["request_slots"]+1):
        await step(valid=(1 << n)-1, eligible=0, masks=[i & 1 for i in range(n)])
    for _ in range(5): await step(ready=0)
    await step(ready=1, correct=True)
    await step(ready=0, kill=True)
    await step(flush=True)
    lanes = (0, 1, br_slot)
    assert ports >= len(lanes)
    burst = sum(1 << i for i in lanes)
    for clock in range(48):
        takes, grants, delivers = await step(valid=burst, one_source=True)
        assert takes == burst, (seed, clock, "intake bubble", takes)
        assert grants == (burst if clock >= 3 else 0), (seed, clock, "three-way read bubble", grants)
        assert delivers == (burst if clock >= 4 else 0), (seed, clock, "three-way delivery bubble", delivers)
    await step(flush=True)
    fma = 1 << fp_base
    for clock in range(48):
        takes, grants, delivers = await step(valid=fma)
        assert takes == fma, (seed, clock, "FMA intake bubble", takes)
        assert delivers == (fma if clock >= 4 else 0), (seed, clock, "FMA delivery bubble", delivers)
    await step(flush=True)
    # A blocked DIV must not backpressure unrelated ALU/BR reads or deliveries.
    div = 1 << (mem_base-1)
    for clock in range(64):
        takes, grants, delivers = await step(valid=burst | div, delivery=((1 << n)-1) ^ div,
                                             one_source=True)
        assert takes & burst == burst, (seed, clock, "blocked DIV stopped intake", takes)
        if clock >= 4:
            assert delivers & burst == burst, (seed, clock, "blocked DIV stopped other FUs", delivers)
    await step(flush=True)
    active_fp = sum(1 << i for i in range(fp_base, n) if cfg["num_fma"] == 2 or i != fp_base+1)
    await step(valid=active_fp)
    for _ in range(12): await step()
    for _ in range(500):
        await step(valid=rng.getrandbits(n), eligible=rng.getrandbits(n), ready=rng.getrandbits(n),
                   delivery=rng.getrandbits(n), kill=rng.randrange(13) == 0,
                   correct=rng.randrange(11) == 0, block=rng.randrange(9) == 0,
                   flush=rng.randrange(51) == 0, reset=rng.randrange(83) == 0,
                   head=rng.randrange(rob_count), masks=[rng.randrange(4) for _ in range(n)])
    for _ in range(6*n+16): await step()
    assert consumed | canceled == accepted, (seed, "lost owners", accepted-(consumed | canceled))
    assert observed >= {"read", "hold", "kill", "resolve", "fp", "mem", "branch"}, observed
