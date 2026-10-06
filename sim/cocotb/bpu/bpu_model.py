"""Public packed-record codecs and a specification-level slow prediction oracle."""


def encode(fields, values):
    bits = 0
    for name, width in fields:
        bits = (bits << width) | (values.get(name, 0) & ((1 << width) - 1))
    return bits


def decode(fields, bits):
    result = {}
    for name, width in reversed(fields):
        result[name] = bits & ((1 << width) - 1)
        bits >>= width
    assert bits == 0
    return result


class Records:
    def __init__(self, addr, idw=13, slotw=3, rasptr=4, rascnt=5,
                 folds=150, history=1024, meta=128):
        self.addr, self.idw, self.slotw = addr, idw, slotw
        slots = 1 << slotw
        self.pred = [('region_base', addr), ('entry_slot', slotw),
                     ('br_mask', slots), ('jal_mask', slots), ('cfi_valid', 1),
                     ('cfi_slot', slotw), ('cfi_type', 2), ('ras_action', 2),
                     ('raw_pred_taken', 1), ('target_missing', 1),
                     ('cfi_target', addr), ('next_pc', addr),
                     ('cfi_is_rvc', 1), ('is_edge', 1)]
        self.btb = [('hit', 1), ('br_mask', slots), ('jal_mask', slots),
                    ('cfi_slot', slotw), ('cfi_type', 2), ('ras_action', 2),
                    ('target', addr), ('cfi_is_rvc', 1), ('is_edge', 1)]
        self.ras = [('top_idx', rasptr), ('count', rascnt), ('top_addr', addr)]
        self.tage = [('taken_mask', slots), ('provider_hit_mask', slots), ('meta', meta)]
        self.hist = [('events', history), ('folds', folds)]
        self.req = [('valid', 1), ('src', 2), ('sys_kind', 3), ('ftq_id', idw),
                    ('slot', slotw), ('kill_self', 1), ('target_pc', addr),
                    ('hist_inject', 1), ('hist_branch_pc', addr),
                    ('hist_target_pc', addr), ('ras_fix', 2), ('ras_push_addr', addr)]
        self.resolve = [('valid', 1), ('mispredict', 1), ('ftq_id', idw), ('slot', slotw),
                        ('branch_pc', addr), ('inst_len', 3), ('cfi_type', 2),
                        ('ras_action', 2), ('actual_taken', 1),
                        ('actual_target', addr), ('redirect_pc', addr)]
        self.sys = [('valid', 1), ('kind', 3), ('ftq_id', idw), ('slot', slotw), ('target_pc', addr)]
        self.train = [('region_base', addr), ('ctx', history+folds), ('tage_meta', meta),
                      ('br_commit_mask', slots), ('br_taken_mask', slots),
                      ('cfi_valid', 1), ('cfi_slot', slotw), ('cfi_type', 2),
                      ('ras_action', 2), ('cfi_target', addr), ('mispredicted', 1),
                      ('cfi_is_rvc', 1), ('is_edge', 1)]


def slow_prediction(fast, btb, tage, ras, slots=8):
    """Enumerate valid candidates, then select the oldest with its own target."""
    p = dict.fromkeys(fast, 0)
    p.update(region_base=fast['region_base'], entry_slot=fast['entry_slot'],
             next_pc=fast['region_base'] + 2*slots)
    if btb['hit']:
        valid = ((1 << slots)-1) ^ ((1 << fast['entry_slot'])-1)
        p.update(br_mask=btb['br_mask'] & valid, jal_mask=btb['jal_mask'] & valid)
        choices = [s for s in range(fast['entry_slot'], slots)
                   if ((p['br_mask'] & tage['taken_mask'] | p['jal_mask']) >> s) & 1
                   or (btb['cfi_type'] == 3 and btb['cfi_slot'] == s)]
        if choices:
            p['raw_pred_taken'] = 1
            chosen = min(choices)
            if chosen == btb['cfi_slot'] and btb['cfi_type'] != 0:
                target = ras['top_addr'] if btb['ras_action'] in (2, 3) and ras['count'] else btb['target']
                p.update(cfi_valid=1, cfi_slot=chosen, cfi_type=btb['cfi_type'],
                         ras_action=btb['ras_action'], cfi_target=target, next_pc=target)
            else:
                p['target_missing'] = 1
    disagree = p['cfi_valid'] != fast['cfi_valid'] or (
        any(p[k] != fast[k] for k in ('cfi_slot', 'cfi_type', 'ras_action', 'next_pc'))
        if p['cfi_valid'] else p['next_pc'] != fast['next_pc'])
    return p, int(disagree)
