"""Independent public-contract model for the first uBTB organization."""

from dataclasses import dataclass, field

CFI_NONE = 0
CFI_BR = 1
CFI_JAL = 2
CFI_JALR = 3
RAS_NONE = 0
RAS_PUSH = 1
RAS_POP = 2


@dataclass(frozen=True)
class Train:
    valid: bool = False
    pc: int = 0
    br_commit_mask: int = 0
    br_taken_mask: int = 0
    cfi_valid: bool = False
    cfi_slot: int = 0
    cfi_type: int = CFI_NONE
    ras_action: int = RAS_NONE
    target: int = 0


@dataclass(frozen=True)
class Inputs:
    rst: bool = False
    query_valid: bool = False
    query_pc: int = 0
    stall: bool = False
    train: Train = field(default_factory=Train)


@dataclass(frozen=True)
class Prediction:
    region_base: int = 0
    entry_slot: int = 0
    br_mask: int = 0
    jal_mask: int = 0
    cfi_valid: bool = False
    cfi_slot: int = 0
    cfi_type: int = CFI_NONE
    ras_action: int = RAS_NONE
    raw_pred_taken: bool = False
    target_missing: bool = False
    target: int = 0
    next_pc: int = 0


@dataclass
class Entry:
    tag: int
    br_mask: int = 0
    jal_mask: int = 0
    owner_valid: bool = False
    cfi_slot: int = 0
    cfi_type: int = CFI_NONE
    ras_action: int = RAS_NONE
    target: int = 0
    br_ctr: int = 0


class UbtbModel:
    def __init__(self, *, vaddr_bits: int, region_bytes: int,
                 entries: int, tag_bits: int, slots: int) -> None:
        assert region_bytes >= 2 and region_bytes & (region_bytes - 1) == 0
        assert slots == region_bytes // 2
        self.vaddr_bits = vaddr_bits
        self.addr_mask = (1 << vaddr_bits) - 1
        self.region_bytes = region_bytes
        self.shift = region_bytes.bit_length() - 1
        self.entries = entries
        self.tag_bits = tag_bits
        self.slots = slots
        self.table: list[Entry | None] = [None] * entries
        self.replace = 0

    def tag_of(self, pc: int) -> int:
        # XOR-fold every region-number bit into the configured partial tag.
        result = 0
        for bit in range(self.shift, self.vaddr_bits):
            if pc & (1 << bit):
                result ^= 1 << ((bit - self.shift) % self.tag_bits)
        return result

    def visible(self, inputs: Inputs) -> tuple[bool, bool, Prediction, int, int]:
        if inputs.rst or inputs.stall or not inputs.query_valid:
            return False, not inputs.rst, Prediction(), 0, 0

        base = inputs.query_pc & ~(self.region_bytes - 1)
        slot = (inputs.query_pc >> 1) & (self.slots - 1)
        next_pc = (base + self.region_bytes) & self.addr_mask
        match = next((e for e in self.table if e is not None and
                      e.tag == self.tag_of(base)), None)
        if match is None:
            return False, True, Prediction(region_base=base, entry_slot=slot,
                                           next_pc=next_pc), 1, 0

        take = match.owner_valid and match.cfi_slot >= slot and (
            match.cfi_type in (CFI_JAL, CFI_JALR) or
            (match.cfi_type == CFI_BR and match.br_ctr >= 2)
        )
        return True, True, Prediction(
            region_base=base, entry_slot=slot,
            br_mask=match.br_mask, jal_mask=match.jal_mask,
            cfi_valid=take,
            cfi_slot=match.cfi_slot if take else 0,
            cfi_type=match.cfi_type if take else CFI_NONE,
            ras_action=match.ras_action if take else RAS_NONE,
            raw_pred_taken=take,
            target=match.target if take else 0,
            next_pc=match.target if take else next_pc,
        ), 1, 1

    def tick(self, inputs: Inputs) -> None:
        if inputs.rst:
            self.table = [None] * self.entries
            self.replace = 0
            return
        t = inputs.train
        if not t.valid or not (t.br_commit_mask or
                               (t.cfi_valid and t.cfi_type != CFI_NONE)):
            return

        tag = self.tag_of(t.pc)
        index = next((i for i, e in enumerate(self.table) if e is not None
                      and e.tag == tag), None)
        matched = index is not None
        if index is None:
            index = next((i for i, e in enumerate(self.table) if e is None), None)
            if index is None:
                index = self.replace
                self.replace = (index + 1) % self.entries
        e = self.table[index] if matched else Entry(tag=tag)
        assert e is not None
        e.br_mask |= t.br_commit_mask
        if t.cfi_valid and t.cfi_type != CFI_NONE:
            if t.cfi_type == CFI_BR:
                e.br_mask |= 1 << t.cfi_slot
                if matched and e.owner_valid and e.cfi_type == CFI_BR and \
                        e.cfi_slot == t.cfi_slot:
                    e.br_ctr = min(3, e.br_ctr + 1)
                else:
                    e.br_ctr = 2
            else:
                e.br_ctr = 0
            if t.cfi_type == CFI_JAL:
                e.jal_mask |= 1 << t.cfi_slot
            e.owner_valid = True
            e.cfi_slot = t.cfi_slot
            e.cfi_type = t.cfi_type
            e.ras_action = t.ras_action
            e.target = t.target
        elif matched and e.owner_valid and e.cfi_type == CFI_BR and \
                t.br_commit_mask & (1 << e.cfi_slot):
            e.br_ctr = max(0, e.br_ctr - 1)
        self.table[index] = e
