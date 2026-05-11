#!/usr/bin/env python3
"""Split a FASTA index into restartable GATK interval chunks.

Standalone helper for inspecting the interval list the workflow will build.
The workflow itself reproduces this logic inline in main.nf.
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

PRIMARY_RE = re.compile(r"^chr([1-9]|1[0-9]|2[0-2]|X|Y)$")


def include_contig(name: str, include_alt: bool, include_mito: bool) -> bool:
    if include_alt:
        return include_mito if name == "chrM" else True
    if name == "chrM":
        return include_mito
    return bool(PRIMARY_RE.match(name))


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--reference-fai", required=True, type=Path)
    p.add_argument("--interval-bp", required=True, type=int)
    p.add_argument("--manifest", required=True, type=Path)
    p.add_argument("--include-alt-contigs", action="store_true")
    p.add_argument("--include-mitochondrial", action="store_true")
    args = p.parse_args()

    args.manifest.parent.mkdir(parents=True, exist_ok=True)

    records: list[dict] = []
    with args.reference_fai.open() as h:
        for line in h:
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 2:
                continue
            contig, length = fields[0], int(fields[1])
            if not include_contig(contig, args.include_alt_contigs, args.include_mitochondrial):
                continue
            start = 1
            while start <= length:
                end = min(start + args.interval_bp - 1, length)
                records.append({
                    "interval_id": f"{len(records) + 1:04d}",
                    "contig": contig,
                    "start": start,
                    "end": end,
                    "interval": f"{contig}:{start}-{end}",
                })
                start = end + 1

    with args.manifest.open("w", newline="") as h:
        w = csv.DictWriter(h, fieldnames=list(records[0].keys()), delimiter="\t")
        w.writeheader()
        w.writerows(records)

    print(f"Wrote {len(records)} intervals to {args.manifest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
