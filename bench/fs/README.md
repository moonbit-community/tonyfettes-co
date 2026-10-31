# Filesystem benchmark

Answers three different questions, because they have three different answers:

| mode | question |
|---|---|
| `seq` | what does a bulk read cost (bandwidth, µs/op)? |
| `rand` | per-op cost and how far queue depth buys IOPS (QD sweep) |
| `stall` | does one cold miss stall the other coroutines? |

Both harnesses drive the *same* workloads: `bench/fs/co_bench` uses `co` +
`co-io` (io_uring), `bench/fs/c/baseline.c` uses `pread` (1 thread, or N
threads = N queue depth). Time is measured per operation inside the process, so
there is no load-generator bottleneck to hide the result.

## Run

```sh
moon build --release --target native
cc -O2 -pthread -o bench/fs/c/baseline bench/fs/c/baseline.c

python3 bench/fs/run.py            # full matrix, prints a markdown table
python3 bench/fs/run.py --quick    # smaller cold file
```

Individual runs:

```sh
co_bench seq   <path> <block> <mib>                  # sequential read
co_bench rand  <path> <block> <qd> <ops> <mib> [evict]
co_bench stall <hot> <cold> <block> <readers> <ops>
baseline seq | pread1 | preadT ...
```

`evict` drops the file's page cache first (`posix_fadvise(POSIX_FADV_DONTNEED)`,
no root needed), which is what makes the cold numbers cold.

## Baseline (i5-1130G7, 4c/8t, 15 GiB RAM, root fs btrfs on dm-crypt, tmpfs)

4 KiB random reads, cache-hot:

| storage | harness | QD=1 | QD=16 | QD=64 |
|---|---|---|---|---|
| btrfs | `co` | 0.80 µs/op, 1.25M IOPS, **1.00 core** | 0.66 µs, 1.52M, **0.99 core** | 0.64 µs, 1.55M, 0.99 core |
| btrfs | `pread` | 0.59 µs/op, 1.70M IOPS, 1.12 cores | 0.14 µs, 7.14M, 4.6 cores | 0.14 µs, 7.33M, 4.7 cores |
| tmpfs | `co` | 4.43 µs/op, 226k IOPS, 0.96 core | 1.04 µs, 958k, 1.9 cores | 1.07 µs, 932k, 1.9 cores |
| tmpfs | `pread` | 0.63 µs/op, 1.59M IOPS, 1.12 cores | 0.16 µs, 6.15M, 8 cores | 0.16 µs, 6.20M, 8 cores |

4 KiB random reads, cold (8 GiB file, page cache dropped before each run):

| harness | QD=1 | QD=16 | QD=64 |
|---|---|---|---|
| `co` | 162 µs/op, 6.2k IOPS | 7.9 µs, 127k, 0.77 core | 6.4 µs, 155k, 0.84 core |
| `pread` | 107 µs/op, 9.3k IOPS | 5.8 µs, 173k, 1.6 cores | 3.1 µs, 324k, 2.9 cores |

Sequential, tmpfs: 4 KiB blocks `co` 4.71 µs/op vs `pread` 0.61 µs/op;
1 MiB blocks `co` 152 µs/op vs `pread` 141 µs/op (8% apart — big blocks amortise
everything).

Head-of-line blocking: 8 coroutines doing hot reads while one coroutine reads
16 MiB from disk. Hot `p50` 5.2 µs, `p99` 11.6 µs, **max 229 µs**, while the
cold read took **36.9 ms**.

## What the numbers mean

**1. Per-op latency depends on whether the filesystem supports `FMODE_NOWAIT`.**
btrfs does: io_uring runs the read inline in `io_uring_enter`, so `co` costs
0.80 µs/op at QD=1 (vs 0.59 µs for a bare `pread` — that 0.2 µs is the
submission machinery). tmpfs does not: every read is punted to an `io-wq`
worker thread, which costs 4.43 µs/op — 7× a plain `pread`. Checked directly by
counting threads: the tmpfs run has an `iou-wrk-*` thread, the btrfs run has
only the main thread. So tmpfs/shm is the pathological case for this path, and
the 4 KiB sequential tmpfs number above is the same effect.

**2. At QD≥4 the story is IOPS per core, not per op.** On btrfs a single `co`
thread does 1.52M IOPS at QD=16 (99% of one core); the pthread baseline needs
4.6 cores for 7.1M, i.e. 1.55M per core. Equal per-core throughput, but `co`
does it with one thread of stack instead of 16 OS threads — and that is the
actual claim to be tested, not "faster IOPS".

**3. Cold reads are disk-bound and queue depth helps more than threads.**
At QD=64, `co` reaches 155k IOPS on 0.84 core (~185k per core); 64 `pread`
threads reach 324k on 2.9 cores (~112k per core). `co` wins per core because a
thread blocks for the whole latency while an SQE does not. At QD=1 `co` is 50%
*slower* (162 vs 107 µs): the extra submission machinery is pure overhead when
there is nothing to overlap.

**4. A cold miss does not stall the other coroutines.** 229 µs worst case while
the cold read needs 36.9 ms, because io_uring punts the would-block read to a
worker instead of blocking the submitter. Note this is the same mechanism that
makes tmpfs slow — the safety and the 4 µs tax are the same design decision.

**5. Threads on the same file are the baseline's weakness, not its strength.**
`pread` numbers at QD=16/64 come from N threads on N cores. Per thread the
baseline is *slower* than one `co` thread; it only wins in aggregate because it
is allowed to use the whole machine.

## Traps

- **`cd` into the repo and `touch io/io.c` after editing `io/io_uring.c`.** The
  `native-stub` build only tracks `io.c`, which `#include`s `io_uring.c`; a stale
  `io.o` silently links the old ABI (this cost an hour: the harness linked a
  5-argument `submit_read` against a 6-argument caller and segfaulted).
- **Writes are not measured here.** There is no `File::sync` (`IORING_OP_FSYNC`)
  yet, so a write benchmark would only measure `memcpy` into the page cache.
  On this machine the root fs is btrfs *on dm-crypt*, so `fdatasync` numbers
  would be ms-scale and variance-dominated anyway.
- **`O_DIRECT` cannot be measured.** It needs 512/4096-aligned buffers, and the
  API takes `FixedArray[Byte]` from the GC heap. That is a real gap, not an
  oversight to work around silently.
- **Page cache dominates everything.** 15 GiB of RAM means any file under a few
  GiB becomes "hot" after one pass. Cold numbers require `evict` (or a file
  larger than RAM).
- **`RWF_NOWAIT` was tried and rejected**: tmpfs returns `EOPNOTSUPP` for it,
  and btrfs already takes the inline path without it, so it bought nothing and
  was reverted. Measure before shipping a "fix" here.
