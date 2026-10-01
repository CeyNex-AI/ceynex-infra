"""Build or compare the counts manifest written beside every backup.

    manifest.py build DIR STAMP          JSON from the .pg_/.neo4j_/.qdrant_ files
                                         ops/lib-counts.sh left in DIR
    manifest.py compare EXPECTED ACTUAL  exit 1 and say what differs

Standard library only: it runs on the VM's system python3.
"""

from __future__ import annotations

import csv
import io
import json
import sys
from pathlib import Path


def _plain_rows(text: str) -> list[list[str]]:
    """cypher-shell --format plain: a header line, then CSV-like rows with
    quoted strings."""
    lines = [line for line in text.splitlines() if line.strip()]
    return [[cell.strip() for cell in row] for row in csv.reader(io.StringIO("\n".join(lines[1:])))]


def build(directory: Path, stamp: str) -> dict:
    read = lambda name: (directory / name).read_text(encoding="utf-8")  # noqa: E731
    postgres = {}
    for line in read(".pg_rows").splitlines():
        if line.strip():
            table, count = line.rsplit(",", 1)
            postgres[table] = int(count)
    return {
        "stamp": stamp,
        "postgres_rows": postgres,
        "postgres_upsert_key": int(read(".pg_upsert").strip() or 0) == 1,
        "neo4j_labels": {row[0]: int(row[1]) for row in _plain_rows(read(".neo4j_labels"))},
        "neo4j_relationships": {row[0]: int(row[1]) for row in _plain_rows(read(".neo4j_rels"))},
        "neo4j_constraints": int(_plain_rows(read(".neo4j_constraints"))[0][0]),
        "qdrant_points": {
            name: int(read(f".qdrant_{name}").strip())
            for name in ("ceynex_policy", "ceynex_news")
        },
    }


def compare(expected: dict, actual: dict) -> list[str]:
    problems = []
    for key in ("postgres_rows", "neo4j_labels", "neo4j_relationships", "qdrant_points"):
        want, got = expected.get(key, {}), actual.get(key, {})
        for name in sorted(set(want) | set(got)):
            if want.get(name) != got.get(name):
                problems.append(f"{key}.{name}: backed up {want.get(name)}, restored {got.get(name)}")
    for key in ("postgres_upsert_key", "neo4j_constraints"):
        if expected.get(key) != actual.get(key):
            problems.append(f"{key}: backed up {expected.get(key)}, restored {actual.get(key)}")
    return problems


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[0] == "build":
        print(json.dumps(build(Path(argv[1]), argv[2]), indent=2, sort_keys=True))
        return 0
    if len(argv) == 3 and argv[0] == "compare":
        expected, actual = (json.loads(Path(p).read_text(encoding="utf-8")) for p in argv[1:])
        problems = compare(expected, actual)
        for problem in problems:
            print(f"MISMATCH {problem}")
        if not problems:
            print(f"OK every count matches backup {expected.get('stamp')}")
        return 1 if problems else 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
