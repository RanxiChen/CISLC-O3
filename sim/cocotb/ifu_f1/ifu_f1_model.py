"""L7a F1 reference model, written from l7a-predictor-spec 4.2-4.4 (U8-U10, U19, U20, U22)."""
from dataclasses import dataclass, field

PC_MASK = (1 << 64) - 1
CFI_NONE, CFI_BR, CFI_JAL, CFI_JALR = range(4)
RAS_NONE, RAS_PUSH, RAS_POP, RAS_POP_PUSH = range(4)
REDIR_PREDECODE = 1
LINK = (1, 5)


def sext(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


# --- RV64I encoders used by the tests ---------------------------------------
def jal(rd, imm):
    imm &= (1 << 21) - 1
    return (((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3FF) << 21 | ((imm >> 11) & 1) << 20
            | ((imm >> 12) & 0xFF) << 12 | rd << 7 | 0x6F)


def jalr(rd, rs1, imm=0):
    return (imm & 0xFFF) << 20 | rs1 << 15 | rd << 7 | 0x67


def branch(rs1, rs2, imm, funct3=0):
    imm &= (1 << 13) - 1
    return (((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3F) << 25 | rs2 << 20 | rs1 << 15
            | funct3 << 12 | ((imm >> 1) & 0xF) << 8 | ((imm >> 11) & 1) << 7 | 0x63)


def addi(rd, rs1, imm):
    return (imm & 0xFFF) << 20 | rs1 << 15 | rd << 7 | 0x13


NOP = addi(0, 0, 0)


def decode(word, pc):
    """Returns (type, ras_action, direct_target) with the backend x1/x5 rule."""
    opcode, rd, rs1, funct3 = word & 0x7F, (word >> 7) & 0x1F, (word >> 15) & 0x1F, (word >> 12) & 7
    if opcode == 0x63 and funct3 not in (2, 3):
        imm = (((word >> 31) & 1) << 12 | ((word >> 7) & 1) << 11
               | ((word >> 25) & 0x3F) << 5 | ((word >> 8) & 0xF) << 1)
        return CFI_BR, RAS_NONE, (pc + sext(imm, 13)) & PC_MASK
    if opcode == 0x6F:
        imm = (((word >> 31) & 1) << 20 | ((word >> 12) & 0xFF) << 12
               | ((word >> 20) & 1) << 11 | ((word >> 21) & 0x3FF) << 1)
        return CFI_JAL, RAS_PUSH if rd in LINK else RAS_NONE, (pc + sext(imm, 21)) & PC_MASK
    if opcode == 0x67 and funct3 == 0:
        if rs1 in LINK:
            if rd in LINK:
                ras = RAS_PUSH if rd == rs1 else RAS_POP_PUSH
            else:
                ras = RAS_POP
        else:
            ras = RAS_PUSH if rd in LINK else RAS_NONE
        return CFI_JALR, ras, None
    return CFI_NONE, RAS_NONE, None


@dataclass(frozen=True)
class Item:
    slot: int
    pc: int
    word: int
    ftq_id: int = 0
    exc: bool = False
    cause: int = 0
    tval: int = 0
    inst_len: int = 4
    edge: bool = False


@dataclass(frozen=True)
class Pred:
    cfi_valid: bool = False
    cfi_slot: int = 0
    cfi_type: int = CFI_NONE
    ras_action: int = RAS_NONE
    cfi_target: int = 0
    next_pc: int = 0
    raw_taken: bool = False
    ras_count: int = 0
    ras_top: int = 0
    rvc: bool = False
    edge: bool = False
    base: int = 0
    ftq_id: int = 0


@dataclass(frozen=True)
class Inputs:
    rst: bool = False
    items: tuple = ()
    pred: Pred = field(default_factory=Pred)
    ready: bool = True
    kill: bool = False
    last: bool = True
    edge_pend: bool = False
    beat: bool = False


def block(base, words, ftq_id=0, start_slot=0, exc=None):
    """Consecutive 32-bit items from `start_slot` (even). exc: {index: (cause, tval)}."""
    exc = exc or {}
    items = []
    for n, word in enumerate(words):
        slot = start_slot + 2 * n
        cause, tval = exc.get(n, (0, 0))
        items.append(Item(slot, base + 2 * slot, word, ftq_id, n in exc, cause, tval))
    return tuple(items)


def evaluate(i: Inputs, width: int):
    """Returns (in_ready, delivered entries, predecode request or None)."""
    ready = i.ready and not (i.rst or i.kill)
    if i.rst or i.kill:
        return ready, [], None
    p = i.pred
    out, req = [], None
    for item in sorted(i.items, key=lambda it: it.slot):
        if len(out) == width:
            break
        s, pc = item.slot, item.pc
        seq = (pc + item.inst_len) & PC_MASK
        start = -1 if item.edge else s
        end = start + (1 if item.inst_len == 4 else 0)
        exit_pos = -1 if p.edge else p.cfi_slot
        is_exit = p.cfi_valid and start == exit_pos
        covers = p.cfi_valid and end >= exit_pos
        earlier = (not p.cfi_valid) or start < exit_pos
        entry = {"pc": pc, "word": item.word, "ftq_id": item.ftq_id, "slot": s,
                 "exc": item.exc, "cause": item.cause, "tval": item.tval,
                 "taken": is_exit, "next_pc": p.next_pc if is_exit else seq, "last": False}
        fix = None  # (taken, target, ras_fix, hist_inject)
        if not item.exc:
            t, ras, direct = decode(item.word, pc)
            if t == CFI_JAL:
                actual = direct
            elif t == CFI_JALR and ras in (RAS_POP, RAS_POP_PUSH) and p.ras_count != 0:
                actual = p.ras_top
            else:
                actual = None
            if earlier and actual is not None:                         # a / b
                fix = (True, actual, ras, False)
            elif covers and (not is_exit or t == CFI_NONE):              # c
                fix = (False, seq, RAS_NONE, False)
            elif is_exit and t != p.cfi_type:                            # d
                fix = (True, actual, ras, False) if actual is not None else (False, seq, RAS_NONE, False)
            elif is_exit and t in (CFI_BR, CFI_JAL) and (
                    p.cfi_target != direct or (t == CFI_JAL and (p.ras_action != ras or (ras in (RAS_PUSH,RAS_POP_PUSH) and p.rvc != (item.inst_len==2))))):  # e
                fix = (True, direct, ras, t == CFI_BR)
            elif is_exit and t == CFI_JALR and (p.ras_action != ras or (ras in (RAS_PUSH,RAS_POP_PUSH) and p.rvc != (item.inst_len==2))):      # f
                fix = (True, actual if actual is not None else p.next_pc, ras, False)
        if fix is not None:
            entry["taken"], entry["next_pc"] = fix[0], fix[1]
            req = {"src": REDIR_PREDECODE, "ftq_id": item.ftq_id, "slot": s, "kill_self": 0,
                   "target": fix[1], "hist_inject": int(fix[3]), "hist_branch": pc,
                   "hist_target": fix[1], "ras_fix": fix[2], "push_addr": seq}
        out.append(entry)
        if fix is not None or item.exc or covers:
            break
    if req is None and i.last and i.edge_pend and p.cfi_valid and not p.edge and p.cfi_slot==7 and not (out and out[-1]['exc']):
        req={'src':REDIR_PREDECODE,'ftq_id':p.ftq_id,'slot':7,'kill_self':0,'target':p.base+16,
             'hist_inject':0,'hist_branch':0,'hist_target':0,'ras_fix':0,'push_addr':0}
    if out and (i.last or req):
        out[-1]["last"] = True
    return ready, out, req
