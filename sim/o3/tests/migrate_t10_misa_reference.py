#!/usr/bin/env python3
"""User-approved, field-exact migration of the archived T09 l9_fp reference."""
import argparse
import hashlib
import json
from pathlib import Path

SOURCE_SHA256 = '7cae0bba9fb513868090ecee6cbc88b78a0ee64b537105fcd27d4e467b6aa365'
OLD_MISA = '0x800000000014112c'
NEW_MISA = '0x800000000014112d'


def migrate(source, target):
    assert source.resolve() != target.resolve(), 'archive must remain untouched'
    original = source.read_bytes()
    assert hashlib.sha256(original).hexdigest() == SOURCE_SHA256, 'unexpected source SHA256'
    lines = original.splitlines(keepends=True)
    rows = [json.loads(line) for line in lines]
    changes = [(7, 0x80000014, 5, 'rd_wdata', OLD_MISA, NEW_MISA),
               (12, 0x80000028, 10, 'instruction', '0x12cf8f93', '0x12df8f93'),
               (12, 0x80000028, 10, 'rd_wdata', OLD_MISA, NEW_MISA)]
    for line_no, pc, order, field, old, new in changes:
        matches = [i for i, r in enumerate(rows) if r.get('type') == 'retire'
                   and int(r.get('pc', '0'), 0) == pc and r.get('order') == order]
        assert matches == [line_no - 1], (field, 'identity is not unique', matches)
        assert rows[line_no - 1][field] == old, (line_no, field, 'unexpected original value')
    result = list(lines)
    for line_no, pc, order, field, old, new in changes:
        old_token = f'"{field}":"{old}"'.encode()
        new_token = f'"{field}":"{new}"'.encode()
        assert result[line_no - 1].count(old_token) == 1, 'field token is not unique'
        result[line_no - 1] = result[line_no - 1].replace(old_token, new_token, 1)
    for i, (before, after) in enumerate(zip(lines, result), 1):
        a, b = json.loads(before), json.loads(after)
        allowed = {field: new for line_no, _, _, field, _, new in changes if line_no == i}
        assert b == {**a, **allowed}, (i, 'unapproved field changed')
        if not allowed:
            assert before == after, (i, 'unapproved byte change')
    migrated = b''.join(result)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        assert target.read_bytes() == migrated, 'existing destination differs'
    else:
        with target.open('xb') as f:
            f.write(migrated)
    assert source.read_bytes() == original, 'archive changed'
    manifest = dict(authorization='用户批准的测试迁移', source=str(source), target=str(target),
                    source_sha256=SOURCE_SHA256, target_sha256=hashlib.sha256(migrated).hexdigest(),
                    line_count=len(lines), changes=[dict(line=n, pc=hex(pc), order=o, field=f,
                    old=old, new=new) for n, pc, o, f, old, new in changes])
    target.with_name(target.name + '.migration.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    args = parser.parse_args()
    print(json.dumps(migrate(args.source, args.target), indent=2, ensure_ascii=False))
