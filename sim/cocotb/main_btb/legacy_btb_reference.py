"""Cycle model of the documented public main_btb contract, not DUT internals."""

from dataclasses import dataclass

CFI_NONE = 0
CFI_BR = 1
CFI_JAL = 2
CFI_JALR = 3

RAS_NONE = 0
RAS_PUSH = 1
RAS_POP = 2
RAS_POP_PUSH = 3


@dataclass(frozen=True)
class Train:
    valid: bool = False
    pc: int = 0
    br_commit_mask: int = 0
    br_taken_mask: int = 0
    cfi_valid: bool = False  # A committed taken CFI, not any decoded CFI.
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
    kill: bool = False
    train: Train = Train()


@dataclass(frozen=True)
class Response:
    hit: bool = False
    br_mask: int = 0
    jal_mask: int = 0
    cfi_slot: int = 0
    cfi_type: int = CFI_NONE
    ras_action: int = RAS_NONE
    target: int = 0


@dataclass(frozen=True)
class Entry:
    tag: int
    response: Response


@dataclass(frozen=True)
class PendingRead:
    tag: int
    ways: tuple[Entry | None, ...]


class BtbModel:
    def __init__(self, *, vaddr_bits: int, region_bytes: int, sets: int,
                 ways: int, tag_bits: int, slots: int) -> None:
        assert region_bytes > 0 and region_bytes & (region_bytes - 1) == 0
        assert sets > 0 and sets & (sets - 1) == 0
        assert ways >= 2 and tag_bits >= 1 and slots == region_bytes // 2
        self.vaddr_bits = vaddr_bits
        self.region_bytes = region_bytes
        self.region_shift = region_bytes.bit_length() - 1
        self.sets = sets
        self.set_bits = sets.bit_length() - 1
        self.ways = ways
        self.tag_bits = tag_bits
        self.slots = slots
        self.reset()

    def reset(self) -> None:
        self.table: list[list[Entry | None]] = [
            [None for _ in range(self.ways)] for _ in range(self.sets)
        ]
        self.victim = [0 for _ in range(self.sets)]
        self.pending: PendingRead | None = None

    def set_of(self, pc: int) -> int:
        return (pc >> self.region_shift) & (self.sets - 1)

    def tag_of(self, pc: int) -> int:
        # XOR-fold all address bits above the set. Partial-tag aliases are
        # permitted by the first-version BTB contract.
        tag = 0
        first = self.region_shift + self.set_bits
        for bit in range(first, self.vaddr_bits):
            if pc & (1 << bit):
                tag ^= 1 << ((bit - first) % self.tag_bits)
        return tag

    def visible(self, inputs: Inputs) -> tuple[bool, Response]:
        if inputs.rst or inputs.stall or inputs.kill or self.pending is None:
            return False, Response()
        for entry in self.pending.ways:
            if entry is not None and entry.tag == self.pending.tag:
                return True, entry.response
        return True, Response()  # A valid query can miss.

    def tick(self, inputs: Inputs) -> None:
        if inputs.rst:
            self.reset()
            return

        # Read-before-write: capture a value snapshot before this edge's
        # independent commit training changes the table.
        if inputs.kill:
            self.pending = None
        elif not inputs.stall:
            if inputs.query_valid:
                index = self.set_of(inputs.query_pc)
                self.pending = PendingRead(self.tag_of(inputs.query_pc),
                                           tuple(self.table[index]))
            else:
                self.pending = None

        train = inputs.train
        if not train.valid or (train.br_commit_mask == 0 and
                               not (train.cfi_valid and train.cfi_type != CFI_NONE)):
            return

        index = self.set_of(train.pc)
        tag = self.tag_of(train.pc)
        row = self.table[index]
        match = next((way for way, entry in enumerate(row)
                      if entry is not None and entry.tag == tag), None)
        empty = next((way for way, entry in enumerate(row)
                      if entry is None), None)
        way = match if match is not None else (
            empty if empty is not None else self.victim[index]
        )
        old = row[way].response if match is not None else Response()
        br_mask = old.br_mask | train.br_commit_mask
        jal_mask = old.jal_mask
        owner_slot, owner_type = old.cfi_slot, old.cfi_type
        ras_action, target = old.ras_action, old.target
        if train.cfi_valid and train.cfi_type != CFI_NONE:
            assert 0 <= train.cfi_slot < self.slots
            if train.cfi_type == CFI_BR:
                br_mask |= 1 << train.cfi_slot
            elif train.cfi_type == CFI_JAL:
                jal_mask |= 1 << train.cfi_slot
            owner_slot, owner_type = train.cfi_slot, train.cfi_type
            ras_action, target = train.ras_action, train.target
        row[way] = Entry(tag, Response(True, br_mask, jal_mask,
                                       owner_slot, owner_type,
                                       ras_action, target))
        if match is None and empty is None:
            self.victim[index] = (way + 1) % self.ways
