"""Single outstanding return contract, modeled as a transaction slot."""
from dataclasses import dataclass


@dataclass(frozen=True)
class Inputs:
    rst: bool = False
    reserve: bool = False
    reserve_id: int = 0
    reserve_pc: int = 0
    response: bool = False
    response_idx: int = 0
    response_id: int = 0
    response_data: int = 0
    brief_done: bool = False
    brief_id: int = 0
    deq_ready: bool = False
    kill: bool = False
    kill_all: bool = False
    kill_self: bool = False
    kill_id: int = 0
    kill_slot: int = 0
    head: int = 0


@dataclass
class Entry:
    ftq_id: int
    pc: int
    data: int | None = None


class ReturnModel:
    def __init__(self, depth=32):
        self.depth = depth
        self.entry: Entry | None = None

    def visible(self, i: Inputs):
        e = self.entry
        ready = e is None and not i.rst and not i.kill
        brief_read = e is not None and e.data is not None
        deq = (brief_read and not i.rst and not i.kill
               and i.brief_done and i.brief_id == e.ftq_id)
        return ready, brief_read, bool(deq), e

    def tick(self, i: Inputs):
        idx_mask = self.depth - 1
        younger = self.entry is not None and (
            ((self.entry.ftq_id & idx_mask) - (i.head & idx_mask)) % self.depth
            > ((i.kill_id & idx_mask) - (i.head & idx_mask)) % self.depth)
        at_boundary = self.entry is not None and self.entry.ftq_id == i.kill_id and i.kill_slot == 0
        if i.rst or (i.kill and (i.kill_all or younger or (i.kill_self and at_boundary))):
            self.entry = None
            return
        ready, _, deq, _ = self.visible(i)
        if deq and i.deq_ready:
            self.entry = None
        if i.reserve and ready:
            self.entry = Entry(i.reserve_id, i.reserve_pc)
        if (i.response and i.response_idx == 0 and self.entry is not None
                and i.response_id == self.entry.ftq_id):
            self.entry.data = i.response_data
