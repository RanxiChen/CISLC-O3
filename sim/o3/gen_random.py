#!/usr/bin/env python3
"""Deterministic legal RV64I, natural alignment, bounded backward branches.

Python random.Random(seed); x1=data base, x2=countdown, x3=tohost.
Weighted template choices 45/15/5/20/15; metadata records both choices and
exact dynamic retirement budget (including loop expansions, excluding skipped
wrong-path instructions). No DUT-derived data is used in generation.
"""
import argparse
import json
import random
from collections import Counter
from pathlib import Path

BASE = 0x80000000
DATA = 0x80100000
TOHOST = 0x8010FFF8


def i(op, rd, f3, rs, imm):
    return ((imm & 0xfff) << 20) | (rs << 15) | (f3 << 12) | (rd << 7) | op


def r(rd, f3, a, b, f7=0, op=0x33):
    return (f7 << 25) | (b << 20) | (a << 15) | (f3 << 12) | (rd << 7) | op


def store(f3, base, rs, imm):
    return ((imm & 0xfe0) << 20) | (rs << 20) | (base << 15) | (f3 << 12) | ((imm & 31) << 7) | 0x23


def branch(f3, a, b, off):
    return ((off >> 12 & 1) << 31) | ((off >> 5 & 63) << 25) | (b << 20) | (a << 15) | (f3 << 12) | ((off >> 1 & 15) << 8) | ((off >> 11 & 1) << 7) | 0x63


def jal(rd, off):
    return ((off >> 20 & 1) << 31) | ((off >> 1 & 1023) << 21) | ((off >> 11 & 1) << 20) | ((off >> 12 & 255) << 12) | (rd << 7) | 0x6f


def generate(seed, target):
    if target < 2000:
        raise ValueError('dynamic retirement target must be >=2000')
    rng = random.Random(seed)
    # AUIPC preserves positive 64-bit addresses (LUI sign extends on RV64).
    words = [0x00100097, 0x00100197, i(0x13, 3, 0, 3, -8)]
    # x3 AUIPC at pc+4 -> data+4, then -8; add 64 KiB for mailbox.
    words[1] = 0x00110197  # data+0x10000+4
    words[2] = i(0x13, 3, 0, 3, -12)  # 0x8010fff8
    # x2 is a temporary handler pointer; bounded loops overwrite it later.
    words += [0x00008117, i(0x13,2,0,2,-12), (0x305<<20)|(2<<15)|(1<<12)|0x73]
    dynamic = 6
    choices = Counter()
    loop_counts = []
    # Seed all non-reserved registers; this is setup, outside mixture.
    for rd in range(4, 32):
        words.append(i(0x13, rd, 0, 0, rng.randint(-2048, 2047)))
        dynamic += 1
    while dynamic < target - 2:
        kind = 'system' if rng.random()<.05 else rng.choices(['alu', 'branch', 'jal', 'load', 'store'], [45, 15, 5, 20, 15])[0]
        choices[kind] += 1
        rd, a, b = (rng.randrange(4, 32) for _ in range(3))
        block, count = [], 1
        if kind == 'system':
            if rng.randrange(3)==0:
                block=[rng.choice([0x00000073,0x00100073,0x0000000b])]
                count=8 # one trap event plus seven real handler retirements
            else:
                addr=rng.choice([0x340,0x305,0x341,0x342,0x343])
                op=rng.choice([1,2,3,5,6,7]);source=a if op<4 else rng.randrange(32)
                if addr==0x305:op=rng.choice([6,7]);source=rng.choice([0,1])
                block=[(addr<<20)|(source<<15)|(op<<12)|(rd<<7)|0x73]
        elif kind == 'alu':
            mode = rng.randrange(5)
            if mode == 0:
                block = [i(0x13, rd, rng.choice([0, 2, 3, 4, 6, 7]), a, rng.randint(-2048, 2047))]
            elif mode == 1:
                f3 = rng.choice([1, 5]); arith = f3 == 5 and rng.randrange(2)
                block = [i(0x13, rd, f3, a, rng.randrange(64) | (0x400 if arith else 0))]
            elif mode == 2:
                f3 = rng.randrange(8)
                block = [r(rd, f3, a, b, 0x20 if f3 in [0, 5] and rng.randrange(2) else 0)]
            elif mode == 3:
                f3 = rng.choice([0, 1, 5])
                block = [r(rd, f3, a, b, 0x20 if f3 in [0, 5] and rng.randrange(2) else 0, 0x3b)]
            else:
                block = [i(0x1b, rd, 0, a, rng.randint(-2048, 2047))]
        elif kind == 'branch':
            if rng.randrange(4) == 0:
                n = rng.randint(1, 8)
                block = [i(0x13, 2, 0, 0, n), i(0x13, rd, 0, rd, 1),
                         i(0x13, 2, 0, 2, -1), branch(1, 2, 0, -8)]
                count = 1 + n * 3
                loop_counts.append(n)
            else:
                # All six branch predicates, deterministic equality/order on x0.
                f3 = rng.choice([0, 1, 4, 5, 6, 7])
                taken = f3 in [0, 5, 7]
                block = [branch(f3, 0, 0, 8), i(0x13, rd, 0, a, 1)]
                count = 1 if taken else 2
        elif kind == 'jal':
            block = [jal(rng.choice([0, rd]), 8), i(0x13, rd, 0, a, 17)]
        else:
            f3 = rng.choice([0, 1, 2, 3, 4, 5, 6]) if kind == 'load' else rng.randrange(4)
            size = 1 << (f3 & 3)
            # Offsets stay in the frozen 64 KiB window; natural alignment.
            off = rng.randrange(0, 2048 // size) * size
            if kind == 'load' and rng.randrange(16) == 0:
                rd = 0
            block = [i(0x03, rd, f3, 1, off) if kind == 'load' else store(f3, 1, b, off)]
        if dynamic + count > target - 2:
            block, count = [i(0x13, rd, 0, a, 0)], 1
        words.extend(block)
        dynamic += count
    words.extend([i(0x13, 2, 0, 0, 1), store(3, 3, 2, 0), jal(0, 0)])
    dynamic += 2
    # Keep x31's live value across traps; mscratch is intentionally observable
    # scratch state. Read mcause and mepc, advance by one 32-bit faulting insn.
    def csr(addr,rd,op,rs):return (addr<<20)|(rs<<15)|(op<<12)|(rd<<7)|0x73
    handler=[csr(0x340,31,1,31),csr(0x342,31,2,0),csr(0x341,31,2,0),
             i(0x13,31,0,31,4),csr(0x341,0,1,31),csr(0x340,31,1,31),0x30200073]
    if len(words)>8192:raise ValueError('random code overlaps handler')
    words += [i(0x13,0,0,0,0)]*(8192-len(words))+handler
    return words, {'seed': seed, 'dynamic_target': dynamic, 'count_unit':'architectural events including traps', 'tohost': hex(TOHOST),
                   'templates': dict(choices), 'backward_iterations': loop_counts,
                   'max_backward_iterations': max(loop_counts, default=0),
                   'static_words': len(words)}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--seed', type=int, required=True)
    p.add_argument('--target', type=int, default=3000)
    p.add_argument('--output', required=True)
    a = p.parse_args()
    words, meta = generate(a.seed, a.target)
    path = Path(a.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Zero the whole window: DUT test RAM does not reset its contents.
    text = '@0x80000000\n' + ''.join(f'{w:08x}\n' for w in words)
    text += '@0x80100000\n' + '00000000\n' * (65536 // 4)
    path.write_text(text)
    path.with_suffix('.meta.json').write_text(json.dumps(meta, indent=2) + '\n')


if __name__ == '__main__':
    main()
