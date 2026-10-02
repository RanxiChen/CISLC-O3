"""Cycle and training model for the public first-version TAGE contract."""

from copy import deepcopy
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Train:
    valid: bool = False
    pc: int = 0
    folds: int = 0
    meta: int = 0
    commit_mask: int = 0
    taken_mask: int = 0


@dataclass(frozen=True)
class Inputs:
    rst: bool = False
    query_valid: bool = False
    pc: int = 0
    folds: int = 0
    stall: bool = False
    kill: bool = False
    train: Train = field(default_factory=Train)


@dataclass(frozen=True)
class Response:
    taken_mask: int = 0
    provider_hit_mask: int = 0
    meta: int = 0


@dataclass
class Row:
    valid: bool
    tag: int
    ctr: list[int]
    useful: list[int]


@dataclass(frozen=True)
class Query:
    pc: int
    folds: int
    base_idx: int
    idx: tuple[int, ...]
    tags: tuple[int, ...]


@dataclass
class Snapshot:
    query: Query
    base: list[int]
    rows: list[Row]


class TageModel:
    def __init__(self, *, vaddr_bits: int, region_bytes: int,
                 slots: int, tables: int, base_entries: int,
                 index_bits: list[int], tag_bits: list[int],
                 ctr_bits: int, useful_bits: int) -> None:
        assert region_bytes & (region_bytes - 1) == 0
        assert base_entries & (base_entries - 1) == 0
        self.vaddr_bits = vaddr_bits
        self.shift = region_bytes.bit_length() - 1
        self.slots = slots
        self.tables = tables
        self.base_entries = base_entries
        self.index_bits = index_bits
        self.tag_bits = tag_bits
        self.ctr_bits = ctr_bits
        self.useful_bits = useful_bits
        self.weak_nt = (1 << (ctr_bits - 1)) - 1
        self.weak_taken = self.weak_nt + 1
        self.ctr_max = (1 << ctr_bits) - 1
        self.useful_max = (1 << useful_bits) - 1
        self.base_code = 7
        self.alt_offset = slots * 3
        self.provider_pred_offset = self.alt_offset + slots
        self.final_offset = self.provider_pred_offset + slots
        self.reset()

    def reset(self) -> None:
        self.base = [[self.weak_nt] * self.slots
                     for _ in range(self.base_entries)]
        self.tagged = [[Row(False, 0, [0] * self.slots, [0] * self.slots)
                        for _ in range(1 << self.index_bits[t])]
                       for t in range(self.tables)]
        self.s1: Query | None = None
        self.s2: Snapshot | None = None

    def pc_fold(self, pc: int, width: int) -> int:
        result = 0
        for bit in range(self.shift, self.vaddr_bits):
            if pc & (1 << bit):
                result ^= 1 << ((bit - self.shift) % width)
        return result

    def query(self, pc: int, folds: int) -> Query:
        idx = []
        tags = []
        offset = 0
        for t in range(self.tables):
            n = self.index_bits[t]
            width = self.tag_bits[t]
            hist_idx = (folds >> offset) & ((1 << n) - 1)
            hist_tag = (folds >> (offset + n)) & ((1 << width) - 1)
            hist_short = (folds >> (offset + n + width)) & ((1 << (width - 1)) - 1)
            idx.append((self.pc_fold(pc, n) ^ hist_idx) & ((1 << n) - 1))
            tags.append((self.pc_fold(pc, width) ^ hist_tag ^
                         (hist_short << 1)) & ((1 << width) - 1))
            offset += n + 2 * width - 1
        base_idx = self.pc_fold(pc, self.base_entries.bit_length() - 1)
        return Query(pc, folds, base_idx, tuple(idx), tuple(tags))

    def snapshot(self, query: Query) -> Snapshot:
        return Snapshot(query, self.base[query.base_idx].copy(),
                        [deepcopy(self.tagged[t][query.idx[t]])
                         for t in range(self.tables)])

    def predict(self, snapshot: Snapshot) -> Response:
        taken = 0
        provider_hit = 0
        meta = 0
        for slot in range(self.slots):
            provider = self.base_code
            provider_ctr = snapshot.base[slot]
            provider_pred = (provider_ctr >> (self.ctr_bits - 1)) & 1
            alt_pred = provider_pred
            useful = 0
            for t, row in enumerate(snapshot.rows):
                if row.valid and row.tag == snapshot.query.tags[t]:
                    alt_pred = provider_pred
                    provider = t
                    provider_ctr = row.ctr[slot]
                    provider_pred = (provider_ctr >> (self.ctr_bits - 1)) & 1
                    useful = row.useful[slot]
            final = provider_pred
            if provider != self.base_code and useful == 0 and \
                    provider_ctr in (self.weak_nt, self.weak_taken):
                final = alt_pred
            taken |= final << slot
            provider_hit |= (provider != self.base_code) << slot
            meta |= provider << (slot * 3)
            meta |= alt_pred << (self.alt_offset + slot)
            meta |= provider_pred << (self.provider_pred_offset + slot)
            meta |= final << (self.final_offset + slot)
        return Response(taken, provider_hit, meta)

    def visible(self, inputs: Inputs) -> tuple[bool, bool, Response]:
        valid = self.s2 is not None and not (inputs.rst or inputs.stall or inputs.kill)
        return valid, not inputs.rst, self.predict(self.s2) if valid else Response()

    def train_ctr(self, ctr: int, taken: int) -> int:
        return min(self.ctr_max, ctr + 1) if taken else max(0, ctr - 1)

    def train_useful(self, useful: int, up: bool) -> int:
        return min(self.useful_max, useful + 1) if up else max(0, useful - 1)

    def train(self, packet: Train) -> None:
        if not packet.valid or not packet.commit_mask:
            return
        query = self.query(packet.pc, packet.folds)
        original = [deepcopy(self.tagged[t][query.idx[t]])
                    for t in range(self.tables)]
        updated = deepcopy(original)
        touched = [False] * self.tables
        for slot in range(self.slots):
            if not (packet.commit_mask & (1 << slot)):
                continue
            actual = (packet.taken_mask >> slot) & 1
            self.base[query.base_idx][slot] = self.train_ctr(
                self.base[query.base_idx][slot], actual)
            provider = (packet.meta >> (slot * 3)) & 7
            alt_pred = (packet.meta >> (self.alt_offset + slot)) & 1
            provider_pred = (packet.meta >> (self.provider_pred_offset + slot)) & 1
            final = (packet.meta >> (self.final_offset + slot)) & 1
            if provider < self.tables and original[provider].valid and \
                    original[provider].tag == query.tags[provider]:
                updated[provider].ctr[slot] = self.train_ctr(
                    updated[provider].ctr[slot], actual)
                if provider_pred != alt_pred:
                    updated[provider].useful[slot] = self.train_useful(
                        updated[provider].useful[slot], provider_pred == actual)
                touched[provider] = True
            if final != actual:
                first_longer = provider + 1 if provider < self.tables else 0
                allocated = False
                for t in range(first_longer, self.tables):
                    row = updated[t]
                    if not (not row.valid or row.tag == query.tags[t] or
                            all(u == 0 for u in row.useful)):
                        continue
                    if not row.valid or row.tag != query.tags[t]:
                        row = Row(True, query.tags[t],
                                  [self.weak_nt] * self.slots, [0] * self.slots)
                        updated[t] = row
                    row.ctr[slot] = self.weak_taken if actual else self.weak_nt
                    row.useful[slot] = 0
                    touched[t] = True
                    allocated = True
                    break
                if not allocated and first_longer < self.tables:
                    row = updated[first_longer]
                    row.useful = [self.train_useful(u, False) for u in row.useful]
                    touched[first_longer] = True
        for t in range(self.tables):
            if touched[t]:
                self.tagged[t][query.idx[t]] = updated[t]

    def tick(self, inputs: Inputs) -> None:
        if inputs.rst:
            self.reset()
            return
        if inputs.kill:
            self.s1 = None
            self.s2 = None
        elif not inputs.stall:
            self.s2 = self.snapshot(self.s1) if self.s1 is not None else None
            self.s1 = self.query(inputs.pc, inputs.folds) if inputs.query_valid else None
        # Reads above sample the old table; training becomes visible to later reads.
        self.train(inputs.train)
