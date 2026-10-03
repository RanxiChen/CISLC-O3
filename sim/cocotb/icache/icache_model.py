"""Reference behavior for the exercised physical-address ICache subset."""

class CacheModel:
    def __init__(self, line_bytes=64, region_bytes=16):
        self.line_bytes = line_bytes
        self.region_bytes = region_bytes
        self.lines = {}

    def install(self, line_address, data):
        assert line_address % self.line_bytes == 0
        assert len(data) == self.line_bytes
        self.lines[line_address] = bytes(data)

    def region(self, address):
        line_address = address - address % self.line_bytes
        offset = address - line_address
        return int.from_bytes(
            self.lines[line_address][offset:offset + self.region_bytes], "little"
        )

    def bank(self, address, bank_count):
        return (address // self.line_bytes) % bank_count
