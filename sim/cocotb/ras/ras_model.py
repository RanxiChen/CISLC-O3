"""Independent ring-stack state model for the public RAS timing contract."""

from dataclasses import dataclass

NONE, PUSH, POP, POP_PUSH = range(4)


@dataclass(frozen=True)
class Checkpoint:
    idx: int
    count: int
    addr: int


@dataclass(frozen=True)
class Inputs:
    reset: bool = False
    op_valid: bool = False
    op: int = NONE
    op_addr: int = 0
    recover: bool = False
    recover_id: int = 0
    ckpt: Checkpoint = Checkpoint(0, 0, 0)
    fix: int = NONE
    fix_addr: int = 0


class RasModel:
    def __init__(self, depth: int):
        self.depth = depth
        self.reset()

    def reset(self):
        self.entries = [0] * self.depth
        self.idx = self.depth - 1
        self.count = 0

    def checkpoint(self) -> Checkpoint:
        return Checkpoint(self.idx, self.count,
                          self.entries[self.idx] if self.count else 0)

    def events(self, inp: Inputs) -> int:
        if inp.reset or not (inp.recover or inp.op_valid):
            return 0
        count = inp.ckpt.count if inp.recover else self.count
        action = inp.fix if inp.recover else inp.op
        push = action in (PUSH, POP_PUSH)
        pop = action in (POP, POP_PUSH)
        underflow = pop and count == 0
        overflow = action == PUSH and count == self.depth
        return (int(push) | (int(pop) << 1) | (int(underflow) << 2)
                | (int(overflow) << 3) | (int(inp.recover) << 4))

    def advance(self, inp: Inputs):
        if inp.reset:
            self.reset()
            return
        if not (inp.recover or inp.op_valid):
            return
        if inp.recover:
            self.idx, self.count = inp.ckpt.idx, inp.ckpt.count
            if self.count:
                self.entries[self.idx] = inp.ckpt.addr
        action = inp.fix if inp.recover else inp.op
        addr = inp.fix_addr if inp.recover else inp.op_addr
        if action == PUSH:
            self.idx = (self.idx + 1) % self.depth
            self.entries[self.idx] = addr
            self.count = min(self.count + 1, self.depth)
        elif action == POP:
            if self.count:
                self.idx = (self.idx - 1) % self.depth
                self.count -= 1
        elif action == POP_PUSH:
            if not self.count:
                self.idx = (self.idx + 1) % self.depth
                self.count = 1
            self.entries[self.idx] = addr
