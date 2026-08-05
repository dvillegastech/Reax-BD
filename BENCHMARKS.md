# ReaxDB benchmarks

Every number on this page was produced by
[`benchmark/reaxdb_benchmark.dart`](benchmark/reaxdb_benchmark.dart) on the
machine described below, on the date below. Nothing here is estimated,
extrapolated, or copied from anyone else's measurements. If a number is not in
this file, it was not measured.

## What was measured, and how

**Date:** 30 July 2026

**Machine**

| | |
| --- | --- |
| Model | Apple M5 Pro, 15 logical cores |
| Memory | 24 GiB |
| Storage | Internal NVMe SSD, APFS |
| OS | macOS 26.5.2 (build 25F84) |
| Dart | 3.11.1 (stable), `macos_arm64` |
| Asserts | disabled (the harness prints this; it was `false` for this run) |

**Command**

```bash
dart run benchmark/reaxdb_benchmark.dart \
  --sizes=1000,10000,100000 --runs=3 --sync=full,none --json=results.json
```

That single command produced every row in the table below. Three repetitions of
each scenario were run; the reported row is the **median repetition**, and the
`run spread` column is the gap between the slowest and the fastest repetition,
so you can see for yourself how stable each measurement was.

**Method**

- Every individual operation is timed with a `Stopwatch` at microsecond
  resolution. The first 10% of samples in each repetition are discarded as
  warmup.
- `p50` / `p95` / `p99` / `max` are per-sample latency. Where fewer than 20
  samples exist the tail percentiles are shown as `n/a` rather than invented.
- `ops/sec` counts **items**: a 500-document batch counts as 500 documents, so
  batch and single-write throughput are directly comparable.
- Documents are `{id, name, category, score, active, payload}` with a 200-byte
  payload. Keys are `bench:%09d`.
- Each repetition runs against a freshly created database in a temporary
  directory, which is deleted afterwards.

`benchmark/README.md` documents every flag and scenario if you want to
reproduce or vary this.

## No cross-database comparison was run

**ReaxDB has not been benchmarked against Hive, Isar, sqflite, SQLite, ObjectBox
or anything else.** Earlier versions of this file contained such a comparison,
built from numbers other projects published for other hardware, other Dart
versions and other workloads, mixed with figures explicitly labelled
"estimated". Those were not measurements, and they have been removed rather
than refreshed. If you need to know how ReaxDB compares with another database
for your workload, benchmark both on your hardware; this harness is a
reasonable starting point for the ReaxDB half.

## Headline results

### Durability is the biggest lever

`SyncMode.full` fsyncs the write-ahead log before a write is acknowledged;
`SyncMode.none` leaves the write in a buffer. At 100,000 documents:

| Operation | `SyncMode.full` (durable) | `SyncMode.none` (buffered) | Ratio |
| --- | ---: | ---: | ---: |
| Sequential write, p50 | 65 us | 4 us | 16x |
| Sequential write, ops/sec | 12,001 | 58,805 | 4.9x |
| Random write, p50 | 71 us | 8 us | 8.9x |
| Transaction commit, p50 | 77 us | 8 us | 9.6x |

This is the honest trade-off, and it is what the modes mean. The
`reopen_wal_replay` scenario makes the consequence concrete: a child process
writes N documents and is killed without closing the database, then the parent
opens it and counts what survived the replay.

| Documents acknowledged | Recovered with `SyncMode.full` | Recovered with `SyncMode.none` |
| ---: | ---: | ---: |
| 1,000 | 1,000 | 991 |
| 10,000 | 10,000 | 9,856 |
| 100,000 | 100,000 | 99,964 |

`SyncMode.none` lost acknowledged writes in every single run. That is the
documented meaning of the mode, not a defect, but it is why `SyncMode.full` is
the default and why the buffered numbers above must never be quoted as
"ReaxDB's write performance" without the caveat.

### Batching amortises the fsync

At 100,000 documents a 500-document `putBatch` costs one WAL sync for the whole
batch:

| Path | `SyncMode.full` | `SyncMode.none` |
| --- | ---: | ---: |
| `put`, one document at a time | 12,001 docs/sec | 58,805 docs/sec |
| `putBatch`, 500 documents | 62,793 docs/sec | 63,606 docs/sec |

Batching is a 5.2x improvement for durable writes, and it makes the sync mode
almost irrelevant (62,793 vs 63,606): once the fsync is amortised across 500
documents the bottleneck is the memtable flush and compaction, not the sync.
The durable batch path therefore costs essentially nothing over the buffered
one. Batch, and keep the durability.

### Cache hits are not storage reads

These are reported as two separate rows and must not be conflated. The harness
sizes the record cache to hold the whole data set, then measures a first pass
(cache empty, data on disk after a `compact()` and a reopen) and a second pass
over the same keys. The measured cache hit ratio is printed with each row.

| 100,000 documents | p50 | p99 | ops/sec | cache hit ratio |
| --- | ---: | ---: | ---: | ---: |
| `point_read_cold` (SSTable read) | 31 us | 93 us | 27,897 | 0.0% |
| `point_read_warm` (in-process cache) | 1 us | 2 us | 825,431 | 100.0% |

A cache hit is roughly 30x faster than a storage read. Publishing only the warm
number would inflate ReaxDB's apparent read throughput by about thirty times,
so both are published. An application whose cache is smaller than its working
set lands between the two rows.

"Cold" here means *ReaxDB's* record cache and memtable are empty. The operating
system's page cache is not purged (this harness cannot do that portably), so
`point_read_cold` is an upper bound on read performance, not a cold-boot
number.

### Indexes help, but less as the result set grows

`query_indexed` and `query_full_scan` run the same equality query over two
identical collections, one with a secondary index on the field and one without.

| Documents | Matches returned | Indexed p50 | Full-scan p50 | Speed-up |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 50 | 268 us | 4.79 ms | 17.9x |
| 10,000 | 500 | 2.65 ms | 53.86 ms | 20.3x |
| 100,000 | 5,000 | 289 ms | 529 ms | 1.8x |

The index is worth roughly 20x while the result set is small. At 100,000
documents the query matches 5,000 documents, and loading and decoding those
5,000 documents dominates everything the index saved, so the advantage
collapses to 1.8x. This is a real property of the current query layer, not a
measurement artefact: it materialises every matching document. Queries that
select a small fraction of a collection benefit from indexes; queries that
select 5% of a large collection barely do.

## Full results

Median of 3 repetitions. `n` is the number of samples in the reported
repetition; tail percentiles are `n/a` where `n < 20`.

| scenario | docs | sync | unit | n | p50 | p95 | p99 | max | ops/sec | run spread | notes |
| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| sequential_write | 1000 | full | document | 900 | 84.0 us | 155.0 us | 217.0 us | 519.0 us | 10,682 | 25.8% | |
| sequential_write | 1000 | none | document | 900 | 5.0 us | 7.0 us | 69.0 us | 312.0 us | 135,115 | 36.9% | |
| sequential_write | 10000 | full | document | 9000 | 64.0 us | 109.0 us | 160.0 us | 1.64 ms | 13,968 | 4.2% | |
| sequential_write | 10000 | none | document | 9000 | 4.0 us | 5.0 us | 18.0 us | 1.12 ms | 188,269 | 13.2% | |
| sequential_write | 100000 | full | document | 90000 | 65.0 us | 114.0 us | 169.0 us | 441 ms | 12,001 | 1.6% | |
| sequential_write | 100000 | none | document | 90000 | 4.0 us | 6.0 us | 23.0 us | 462 ms | 58,805 | 3.6% | |
| random_write | 1000 | full | document | 900 | 67.0 us | 125.0 us | 177.0 us | 256.0 us | 13,268 | 5.2% | |
| random_write | 1000 | none | document | 900 | 5.0 us | 7.0 us | 14.0 us | 146.0 us | 165,168 | 9.3% | |
| random_write | 10000 | full | document | 9000 | 70.0 us | 118.0 us | 168.0 us | 1.10 ms | 13,022 | 6.4% | |
| random_write | 10000 | none | document | 9000 | 7.0 us | 10.0 us | 34.0 us | 1.46 ms | 120,281 | 10.9% | |
| random_write | 100000 | full | document | 90000 | 71.0 us | 122.0 us | 177.0 us | 822 ms | 10,628 | 0.7% | |
| random_write | 100000 | none | document | 90000 | 8.0 us | 11.0 us | 31.0 us | 851 ms | 39,736 | 2.3% | |
| batch_write | 1000 | full | document | 2 | 2.60 ms | n/a | n/a | 2.84 ms | 192,678 | 32.8% | batch=500 |
| batch_write | 1000 | none | document | 2 | 1.67 ms | n/a | n/a | 1.71 ms | 300,030 | 26.2% | batch=500 |
| batch_write | 10000 | full | document | 18 | 1.82 ms | n/a | n/a | 5.66 ms | 233,712 | 19.5% | batch=500 |
| batch_write | 10000 | none | document | 18 | 1.52 ms | n/a | n/a | 4.12 ms | 280,383 | 16.4% | batch=500 |
| batch_write | 100000 | full | document | 180 | 1.81 ms | 6.76 ms | 109 ms | 489 ms | 62,793 | 4.6% | batch=500 |
| batch_write | 100000 | none | document | 180 | 1.69 ms | 6.96 ms | 108 ms | 479 ms | 63,606 | 1.3% | batch=500 |
| point_read_cold | 1000 | full | read | 900 | 30.0 us | 75.0 us | 95.0 us | 765.0 us | 28,062 | 17.2% | cache hits 0.0% |
| point_read_warm | 1000 | full | read | 900 | 1.0 us | 2.0 us | 4.0 us | 86.0 us | 731,707 | 55.7% | cache hits 100.0% |
| point_read_cold | 10000 | full | read | 9000 | 28.0 us | 64.0 us | 89.0 us | 1.67 ms | 29,851 | 2.8% | cache hits 0.0% |
| point_read_warm | 10000 | full | read | 9000 | 1.0 us | 1.0 us | 2.0 us | 493.0 us | 881,661 | 3.5% | cache hits 100.0% |
| point_read_cold | 100000 | full | read | 90000 | 31.0 us | 65.0 us | 93.0 us | 2.92 ms | 27,897 | 1.6% | cache hits 0.0% |
| point_read_warm | 100000 | full | read | 90000 | 1.0 us | 1.0 us | 2.0 us | 5.08 ms | 825,431 | 8.1% | cache hits 100.0% |
| range_scan | 1000 | full | entry | 18 | 947.5 us | n/a | n/a | 1.43 ms | 108,506 | 18.6% | 100-entry window |
| range_scan | 10000 | full | entry | 90 | 3.56 ms | 8.23 ms | 9.46 ms | 9.81 ms | 25,966 | 12.3% | 100-entry window |
| range_scan | 100000 | full | entry | 450 | 10.88 ms | 16.71 ms | 18.12 ms | 19.13 ms | 9,564 | 6.0% | 100-entry window |
| query_indexed | 1000 | full | query | 36 | 268.0 us | 984.8 us | 1.40 ms | 1.46 ms | 2,609 | 24.2% | 50 matches |
| query_full_scan | 1000 | full | query | 36 | 4.79 ms | 8.13 ms | 9.20 ms | 9.38 ms | 195.3 | 1.5% | 50 matches |
| query_indexed | 10000 | full | query | 36 | 2.65 ms | 20.42 ms | 21.42 ms | 21.61 ms | 118.3 | 14.6% | 500 matches |
| query_full_scan | 10000 | full | query | 36 | 53.86 ms | 58.88 ms | 59.66 ms | 59.97 ms | 18.5 | 4.4% | 500 matches |
| query_indexed | 100000 | full | query | 9 | 289 ms | n/a | n/a | 360 ms | 3.4 | 7.0% | 5000 matches |
| query_full_scan | 100000 | full | query | 9 | 529 ms | n/a | n/a | 561 ms | 1.9 | 5.7% | 5000 matches |
| transaction_commit | 1000 | full | commit | 900 | 75.0 us | 142.0 us | 196.0 us | 532.0 us | 11,849 | 3.1% | 1 op/tx |
| transaction_commit | 1000 | none | commit | 900 | 9.0 us | 11.0 us | 46.1 us | 234.0 us | 95,887 | 9.1% | 1 op/tx |
| transaction_commit | 10000 | full | commit | 9000 | 73.0 us | 122.0 us | 174.0 us | 577.0 us | 12,466 | 1.4% | 1 op/tx |
| transaction_commit | 10000 | none | commit | 9000 | 8.0 us | 11.0 us | 44.0 us | 1.07 ms | 102,318 | 5.8% | 1 op/tx |
| transaction_commit | 100000 | full | commit | 18000 | 77.0 us | 138.0 us | 185.0 us | 33.25 ms | 11,429 | 8.8% | 1 op/tx |
| transaction_commit | 100000 | none | commit | 18000 | 8.0 us | 11.0 us | 47.0 us | 31.01 ms | 79,931 | 6.6% | 1 op/tx |
| reopen_clean | 1000 | full | open | 4 | 1.58 ms | n/a | n/a | 1.90 ms | 640.5 | 6.0% | |
| reopen_clean | 10000 | full | open | 4 | 2.51 ms | n/a | n/a | 2.62 ms | 397.0 | 14.3% | |
| reopen_clean | 100000 | full | open | 4 | 16.84 ms | n/a | n/a | 19.31 ms | 57.3 | 9.9% | |
| reopen_wal_replay | 1000 | full | open | 1 | 6.45 ms | n/a | n/a | 6.45 ms | 155.1 | 20.6% | recovered 1000/1000 |
| reopen_wal_replay | 1000 | none | open | 1 | 5.09 ms | n/a | n/a | 5.09 ms | 196.6 | 55.5% | recovered 991/1000 |
| reopen_wal_replay | 10000 | full | open | 1 | 37.55 ms | n/a | n/a | 37.55 ms | 26.6 | 10.4% | recovered 10000/10000 |
| reopen_wal_replay | 10000 | none | open | 1 | 36.75 ms | n/a | n/a | 36.75 ms | 27.2 | 1.8% | recovered 9856/10000 |
| reopen_wal_replay | 100000 | full | open | 1 | 460 ms | n/a | n/a | 460 ms | 2.2 | 1.5% | recovered 100000/100000 |
| reopen_wal_replay | 100000 | none | open | 1 | 464 ms | n/a | n/a | 464 ms | 2.2 | 2.4% | recovered 99964/100000 |

## Reading the tails

The `max` column is where the compaction work shows up. Individual writes are
tens of microseconds at p99, but the slowest single `put` in the
100,000-document run took 441 ms (`SyncMode.full`) and 462 ms
(`SyncMode.none`), and the slowest 500-document batch took 489 ms. Those are
the calls that happened to trigger a memtable flush plus a multi-level
compaction, which ReaxDB currently performs **inline, on the calling
operation**. If your application cares about worst-case write latency rather
than throughput, that is the number that matters.

Startup behaves the same way. Opening a cleanly closed 100,000-document
database takes 16.84 ms, because the WAL was checkpointed during `close()` and
there is nothing to replay. Opening the same database after a process was
killed takes 460 ms, because all 100,000 records have to be replayed from the
log. Frequent checkpoints buy faster recovery.

Range scans get more expensive per entry as the database grows: a 100-entry
window costs 9.5 us per entry at 1,000 documents, 35.6 us at 10,000 and
108.8 us at 100,000. A short scan has to merge iterators across every level
that could contain the range, so the fixed setup cost of the merge grows with
the number of tables. Short scans over large databases are currently the
weakest part of the read path.

## Limitations of this methodology

Read these before quoting anything above.

1. **One machine, one filesystem, one session.** Everything here is an Apple M5
   Pro with APFS on internal NVMe. A phone, a spinning disk, a network
   filesystem or an emulator will behave differently, sometimes by an order of
   magnitude.
2. **`fsync` is not `F_FULLFSYNC`.** `SyncMode.full` calls
   `RandomAccessFile.flush()`, which is `fsync(2)`. On macOS and APFS that does
   not force the drive's own write cache. The durability being measured is
   "survives a process kill", which is what ReaxDB's contract promises;
   durability against sudden power loss on a drive with a volatile write cache
   is a stronger property that these numbers do not represent.
3. **The OS page cache is warm.** No scenario purges it, so even the "cold"
   reads benefit from it. Treat `point_read_cold` as an upper bound.
4. **Single isolate, no contention.** Every scenario is strictly sequential.
   Nothing here says how ReaxDB behaves with concurrent writers, readers racing
   a compaction, or transactions contending for the same keys. That is what
   `test/stress/` covers, and it is a correctness suite, not a performance one.
5. **200-byte documents only.** Value size was not varied. Large values (the
   stress suite round-trips 1 MiB values) were not benchmarked.
6. **No encryption.** Every measurement uses `EncryptionConfig.none()`.
   AES-256-GCM adds per-record cost that is not reflected here.
7. **Rows with `n < 20` have no meaningful tail.** `batch_write` at 1,000
   documents is two samples. Treat those rows as an order of magnitude.
8. **A `run spread` above roughly 15% means the machine was noisy.** Several
   small-size rows exceed that; `point_read_warm` at 1,000 documents is 55.7%,
   because a 1-microsecond operation sits at the resolution limit of the clock.
   Prefer the 100,000-document rows, whose spreads are mostly under 5%, when
   you need a number you can rely on.
9. **`--runs=3` is a small sample.** Taking the median of three repetitions
   protects against one unlucky run, not against a systematic bias. Raise
   `--runs` if you need tighter confidence.

## Reproducing this

```bash
git clone https://github.com/dvillegastech/Reax-BD
cd Reax-BD
dart pub get
dart run benchmark/reaxdb_benchmark.dart \
  --sizes=1000,10000,100000 --runs=3 --sync=full,none --json=results.json
```

The harness prints the machine, Dart version, core count, assert state and
configuration it ran with, so any output you post is self-describing. See
[`benchmark/README.md`](benchmark/README.md) for the scenario catalogue and the
full option list.
