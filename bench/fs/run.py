#!/usr/bin/env python3
"""Run the filesystem benchmark matrix and print a markdown table.

    python3 bench/fs/run.py [--quick]

Measures, for both `co` (io_uring) and a plain `pread`/pthread baseline:

  * sequential 4 KiB reads (bandwidth + µs/op)
  * random 4 KiB reads at queue depths 1/4/16/64, cache-hot and cold
  * head-of-line blocking: hot readers while one coroutine misses to disk

Every run reports IOPS, µs/op and the process's own CPU time per operation, so
"the syscall path is expensive" can be told apart from "the disk is slow".
"""

import argparse
import os
import resource
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
CO = os.path.join(
    ROOT, "..", "..", "_build/native/release/build/tonyfettes/co-bench/fs/co_bench/co_bench.exe"
)
BASE = os.path.join(ROOT, "c", "baseline")

TMPFS_DIR = "/tmp"
BTRFS_DIR = os.path.expanduser("~/fs-bench")
MIB = 1 << 20


def run(cmd, samples=3):
    """Run a command `samples` times, return the cheapest wall time and its line."""
    best = None
    for _ in range(samples):
        before = resource.getrusage(resource.RUSAGE_CHILDREN)
        start = time.monotonic()
        out = subprocess.run(cmd, capture_output=True, text=True)
        wall = time.monotonic() - start
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        if out.returncode != 0:
            return None
        cpu = (
            (after.ru_utime - before.ru_utime)
            + (after.ru_stime - before.ru_stime)
        )
        if best is None or wall < best[0]:
            best = (wall, cpu, out.stdout.strip())
    return best


def make_files(quick):
    os.makedirs(BTRFS_DIR, exist_ok=True)
    hot_tmp = os.path.join(TMPFS_DIR, "fs-bench-hot.bin")
    hot_disk = os.path.join(BTRFS_DIR, "hot.bin")
    cold_disk = os.path.join(BTRFS_DIR, "cold.bin")
    hot_mib = 64
    cold_gib = 4 if quick else 8

    if not os.path.exists(hot_tmp) or os.path.getsize(hot_tmp) < hot_mib * MIB:
        with open(hot_tmp, "wb") as f:
            f.write(os.urandom(hot_mib * MIB))
    if not os.path.exists(hot_disk) or os.path.getsize(hot_disk) < hot_mib * MIB:
        with open(hot_disk, "wb") as f:
            f.write(os.urandom(hot_mib * MIB))
    if not os.path.exists(cold_disk) or os.path.getsize(cold_disk) < cold_gib << 30:
        print(f"creating {cold_gib} GiB cold file at {cold_disk} ...", file=sys.stderr)
        with open(cold_disk, "wb") as f:
            block = os.urandom(8 * MIB)
            for _ in range((cold_gib << 30) // len(block)):
                f.write(block)
        subprocess.run(["sync"])
    return hot_tmp, hot_disk, cold_disk, hot_mib, cold_gib


def report(rows, label, result, note=""):
    if result is None:
        rows.append((label, "failed", "", "", "", note))
        return
    wall, cpu, line = result
    rows.append((label, line, f"{cpu / wall * 100:.0f}%", note))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="small cold file, fewer ops")
    args = ap.parse_args()
    if not os.path.exists(CO) or not os.path.exists(BASE):
        sys.exit("build first: moon build --release --target native && "
                 "cc -O2 -pthread -o bench/fs/c/baseline bench/fs/c/baseline.c")

    hot_tmp, hot_disk, cold_disk, hot_mib, cold_gib = make_files(args.quick)
    ops = 20000 if args.quick else 100000
    cold_ops = 20000

    print(f"# filesystem benchmark\n")
    print(f"- `co`: {CO}")
    print(f"- baseline: {BASE}")
    print(f"- tmpfs: {hot_tmp} ({hot_mib} MiB, page cache)")
    print(f"- btrfs: {hot_disk} ({hot_mib} MiB), {cold_disk} ({cold_gib} GiB)\n")

    rows = []
    for name, path in (("tmpfs hot", hot_tmp), ("btrfs hot", hot_disk)):
        for qd in (1, 4, 16, 64):
            report(rows, f"co 4 KiB random, {name} qd={qd}",
                   run([CO, "rand", path, "4096", str(qd), str(ops), str(hot_mib)]))
            if qd == 1:
                report(rows, f"pread 4 KiB random, {name} qd=1",
                       run([BASE, "pread1", path, "4096", str(ops), str(hot_mib)]))
            else:
                report(rows, f"pread 4 KiB random, {name} threads={qd}",
                       run([BASE, "preadT", path, "4096", str(qd), str(ops), str(hot_mib)]))

    # Cold: the working set is larger than RAM, and both harnesses drop the page
    # cache for the file right before timing.
    cold_mib = cold_gib * 1024
    for qd in (1, 16, 64):
        report(rows, f"co 4 KiB random, btrfs cold qd={qd}",
               run([CO, "rand", cold_disk, "4096", str(qd), str(cold_ops), str(cold_mib), "evict"], samples=1),
               "evicted")
        if qd == 1:
            report(rows, f"pread 4 KiB random, btrfs cold qd=1",
                   run([BASE, "pread1", cold_disk, "4096", str(cold_ops), str(cold_mib), "evict"], samples=1),
                   "evicted")
        else:
            report(rows, f"pread 4 KiB random, btrfs cold threads={qd}",
                   run([BASE, "preadT", cold_disk, "4096", str(qd), str(cold_ops), str(cold_mib), "evict"], samples=1),
                   "evicted")

    for block, mib in ((4096, 64), (1 << 20, 64)):
        report(rows, f"co sequential {block}B x {mib} MiB, tmpfs",
               run([CO, "seq", hot_tmp, str(block), str(mib)]))
        report(rows, f"pread sequential {block}B x {mib} MiB, tmpfs",
               run([BASE, "seq", hot_tmp, str(block), str(mib)]))

    report(rows, "co head-of-line: hot readers vs one cold read",
           run([CO, "stall", hot_disk, cold_disk, "4096", "8", "20000"], samples=1),
           f"cold file {cold_gib} GiB")

    print("| case | result | cpu | note |")
    print("|---|---|---|---|")
    for label, line, cpu, note in rows:
        print(f"| {label} | `{line}` | {cpu} | {note} |")


if __name__ == "__main__":
    main()
