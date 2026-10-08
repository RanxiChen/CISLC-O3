"""Checks the exact boundary of the user-approved spec 12 exception."""
import json
from pathlib import Path
import tempfile
import unittest
from compare_retire_traces import compare


def event(index, **changes):
    row = dict(type='retire', order=index, cycle=10, slot=index, pc=hex(0x80000000 + index * 4),
               instruction='0x00000013', mem_kind='none', rd_write=False)
    row.update(changes)
    return row


class PrefixComparison(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = event(1, instruction='0x0062b023', mem_kind='store', mem_addr='0x801ff000',
                           mem_size=8, mem_data='0x1')
        self.jump = event(2, instruction='0x0000006f')

    def traces(self, left, right):
        paths = []
        for name, rows in [('left', left), ('right', right)]:
            path = Path(self.tmp.name) / name
            path.write_text('\n'.join(json.dumps(row) for row in [dict(type='header'), *rows]))
            paths.append(path)
        return paths

    def test_only_same_cycle_terminal_jump_count_is_exempt(self):
        left = [event(0), self.store, self.jump, dict(self.jump, order=3, slot=3)]
        right = [event(0), self.store]
        result = compare(*self.traces(left, right), require_tohost=True)
        self.assertTrue(result['passed'])
        self.assertEqual(result['left']['prefix_events'], 2)
        self.assertEqual(result['left']['exempt_tail_events'], 2)
        self.assertEqual(result['right']['exempt_tail_events'], 0)
        self.assertEqual(result['left']['headers_skipped'], 1)

    def test_each_tail_condition_is_required(self):
        for change in [dict(type='trap'), dict(cycle=11), dict(slot=0),
                       dict(instruction='0x00000013'), dict(pc='0x80000100'),
                       dict(rd_write=True), dict(mem_kind='store')]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                compare(*self.traces([event(0), self.store, dict(self.jump, **change)],
                                     [event(0), self.store]), require_tohost=True)

    def test_prefix_type_pc_instruction_and_trap_identity_are_strict(self):
        trap = event(0, type='trap', exc_cause='0x5', exc_tval='0x80004000')
        for change in [dict(type='retire'), dict(pc='0x80000004'),
                       dict(instruction='0x0000006f'), dict(exc_cause='0x7'),
                       dict(exc_tval='0x80005000')]:
            with self.subTest(change=change):
                result = compare(*self.traces([trap, self.store],
                                 [dict(trap, **change), self.store]), require_tohost=True)
                self.assertFalse(result['passed'])
                self.assertEqual(result['first_prefix_divergence']['index'], 0)

    def test_missing_success_and_prefix_length_change_fail(self):
        with self.assertRaises(ValueError):
            compare(*self.traces([event(0), dict(self.store, mem_data='0x3')],
                                 [event(0), self.store]), require_tohost=True)
        self.assertFalse(compare(*self.traces([event(0), self.store], [self.store]),
                                 require_tohost=True)['passed'])

    def test_fixed_retirement_targets_are_compared_in_full(self):
        self.assertFalse(compare(*self.traces([event(0), self.jump], [event(0)]))['passed'])
        self.assertTrue(compare(*self.traces([event(0)], [event(0)]))['passed'])


if __name__ == '__main__':
    unittest.main()
