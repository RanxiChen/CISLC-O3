"""Independent line-memory reference for the current 64B L2 contract."""


def line_bytes(seed, line_bytes=64):
    return bytes(((seed * 17 + offset * 3) & 0xff) for offset in range(line_bytes))


def beat_value(line, beat, beat_bytes=16):
    return int.from_bytes(line[beat * beat_bytes:(beat + 1) * beat_bytes], "little")


def same_set_lines(base, count, sets, line_bytes=64):
    return [base + index * sets * line_bytes for index in range(count)]
