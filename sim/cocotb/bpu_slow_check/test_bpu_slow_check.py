"""Table-driven L7a slow-check contract, including U1/U17 and every comparison."""
import random
import cocotb
from cocotb.triggers import Timer
from bpu_model import Records, encode, decode, slow_prediction


@cocotb.test()
async def candidates_targets_and_overrides(d):
    d.clk_i.value = 0
    await Timer(1, unit='ns')
    r = Records(addr=int(d.addr_w_o.value), idw=len(d.fast_id_i),
                rasptr=int(d.ras_ptr_w_o.value), rascnt=int(d.ras_cnt_w_o.value))
    fast0 = decode(r.pred, encode(r.pred, dict(region_base=0x1000, next_pc=0x1010)))
    btb0 = decode(r.btb, encode(r.btb, dict(hit=1, br_mask=1<<2,
                cfi_slot=2, cfi_type=1, target=0x2000)))
    cases = [
        ('miss', {}, {}, {}, {}),
        ('owner taken', {}, btb0, {'taken_mask':1<<2}, {}),
        ('owner not taken', {}, btb0, {}, {}),
        ('entry masks owner', {'entry_slot':4}, btb0, {'taken_mask':1<<2}, {}),
        ('early missing target', {}, dict(btb0, br_mask=0x5), {'taken_mask':0x5}, {}),
        ('no owner U17', {}, {'hit':1, 'br_mask':1, 'cfi_slot':0, 'cfi_type':0}, {'taken_mask':1}, {}),
        ('jal before BR', {}, dict(btb0, jal_mask=1), {'taken_mask':4}, {}),
        ('jal owner', {}, {'hit':1, 'jal_mask':0x10, 'cfi_slot':4, 'cfi_type':2,
                            'ras_action':1, 'target':0x3000}, {}, {}),
        ('jalr owner', {}, {'hit':1, 'cfi_slot':6, 'cfi_type':3, 'target':0x4000}, {}, {}),
        ('return empty', {}, {'hit':1, 'cfi_slot':2, 'cfi_type':3, 'ras_action':2,
                             'target':0x5000}, {}, {}),
        ('return nonempty', {}, {'hit':1, 'cfi_slot':2, 'cfi_type':3, 'ras_action':2,
                                'target':0x5000}, {}, {'count':1, 'top_addr':0x6000}),
        ('pop push', {}, {'hit':1, 'cfi_slot':2, 'cfi_type':3, 'ras_action':3,
                         'target':0x5000}, {}, {'count':3, 'top_addr':0x7000}),
    ]
    # Generate a matching fast result, then perturb one comparison at a time.
    owner = btb0
    p, _ = slow_prediction(fast0, owner, {'taken_mask':4}, {'count':0})
    cases.append(('exact match', p, owner, {'taken_mask':4}, {}))
    for field, value in [('cfi_valid',0), ('cfi_slot',4), ('cfi_type',2),
                         ('ras_action',1), ('next_pc',0x9000)]:
        cases.append((f'compare {field}', dict(p, **{field:value}), owner, {'taken_mask':4}, {}))
    cases.append(('sequential next differs', {'next_pc':0x9010}, {}, {}, {}))
    rng = random.Random(517)
    for _ in range(100):
        cases.append(('entry/candidate enumeration', {'entry_slot':rng.randrange(8)},
            {'hit':1, 'br_mask':rng.getrandbits(8), 'jal_mask':rng.getrandbits(8),
             'cfi_slot':rng.randrange(8), 'cfi_type':rng.randrange(4),
             'ras_action':rng.randrange(4), 'target':0x2000},
            {'taken_mask':rng.getrandbits(8)}, {'count':rng.randrange(3), 'top_addr':0x8000}))
    for name, fast, btb, tage, ras in cases:
        f = dict(fast0, **fast)
        b = decode(r.btb, encode(r.btb, btb))
        t = decode(r.tage, encode(r.tage, dict(meta=0x123456, **tage)))
        ck = decode(r.ras, encode(r.ras, ras))
        expected, disagreement = slow_prediction(f, b, t, ck)
        d.fast_bits_i.value = encode(r.pred, f)
        d.btb_bits_i.value = encode(r.btb, b)
        d.tage_bits_i.value = encode(r.tage, t)
        d.ras_bits_i.value = encode(r.ras, ck)
        d.fast_id_i.value = 0x47
        d.rst_i.value = 0
        for kill in (0, 1):
            for valid in (1, 0):
                d.kill_valid_i.value = kill
                d.fast_valid_i.value = valid
                await Timer(1, unit='ns')
                assert int(d.valid_o.value) == valid, name
                req = decode(r.req, int(d.req_bits_o.value))
                assert req['valid'] == (valid and disagreement), name
                assert int(d.hit_inc_o.value) == valid*b['hit'], name
                assert int(d.missing_inc_o.value) == valid*expected['target_missing'], name
                assert int(d.disagree_inc_o.value) == valid*disagreement, name
                if valid:
                    assert decode(r.pred, int(d.pred_bits_o.value)) == expected, name
                    assert int(d.meta_o.value) == t['meta'] and int(d.id_o.value) == 0x47, name
                    assert int(d.disagree_o.value) == disagreement, name
                    wanted = dict(valid=disagreement, src=0, ftq_id=0x47,
                        slot=expected['cfi_slot'] if expected['cfi_valid'] else 7,
                        target_pc=expected['next_pc'],
                        hist_inject=int(bool(expected['cfi_valid'] and expected['cfi_type']==1)),
                        hist_branch_pc=0x1000+2*expected['cfi_slot'],
                        hist_target_pc=expected['cfi_target'],
                        ras_fix=expected['ras_action'] if expected['cfi_valid'] else 0,
                        ras_push_addr=0x1000+2*expected['cfi_slot']+4)
                    assert req == decode(r.req, encode(r.req, wanted)), name
