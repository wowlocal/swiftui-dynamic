# Parallel verification architecture

`Scripts/gate.sh` is the repository's bounded parallel verification entry
point. It builds once, runs tests and evaluator checks from the prebuilt
artifacts, preserves every worker's exit status, and accepts a board only after
its aggregate verdict passes the existing gate.

This document is also the tuning guide. Update it whenever the scheduling,
partitioning, cache, or resource-allocation policy changes.

## Why the parallelism uses processes

`SwiftInterpreter` and `SwiftUIBridge` are `MainActor`-isolated. Several eval
scenarios also install process-global state such as network replay policy,
resource roots, registries, and deterministic hashing. Putting multiple evals
in a `TaskGroup` would still serialize interpreter work on `MainActor`; making
that state nonisolated merely to gain throughput would introduce semantic
races.

The parallel unit is therefore a process. Each worker owns its interpreter,
bridge globals, replay policy, and heap. This gives physical CPU parallelism
without weakening runtime isolation. The tradeoff is that peak RSS is the sum
of worker heaps, so worker counts are deliberately bounded.

The reusable implementation is `CheckSupport.ParallelCheckRunner`. A check
invoked with `--jobs N` becomes a coordinator which:

1. removes any existing runner arguments;
2. starts all `N` copies of its own executable before waiting for any one;
3. passes each child `--jobs 1 --shard-index I --shard-count N`;
4. captures stdout and stderr in per-worker files;
5. requires a successful exit and a JSON summary marker from every child;
6. sums counters and validates that the shards covered the original item
   count before printing the one authoritative verdict.

A missing summary, child crash, invalid shard, or coverage-count mismatch is a
hard failure. Child diagnostic output is replayed in stable shard order.

## Partition algorithms

All lists are filtered and limited before partitioning. Equal-cost work uses
round-robin: worker `I` receives each item whose stable zero-based offset
satisfies `offset % N == I`. Work with a stable size proxy uses deterministic
longest-processing-time (LPT) assignment: items are considered by descending
weight, ties use original position, and each item goes to the lowest-load
worker (then lowest worker index). Every child independently reconstructs the
same assignment and retains original order within its shard. Both algorithms
are deterministic, disjoint, complete, and require no shared coordinator
state.

- `ProjectCheck` globally sorts projects by source bytes, applies `--limit`,
  then uses source bytes as the LPT weight. Zip extraction finishes in the
  coordinator before children start.
  Only the coordinator reads a valid full-sweep cache as an early exit and only
  the coordinator records the aggregate full-sweep verdict. Children never
  write `.claude/last-verify.txt`.
- `ParityCheck` shards the generated probe list. Each process owns its
  interpreter. Native stability, missing, match, divergence, and error counts
  are computed only for that child's selected probes and then summed.
- `LiveCheck` applies `--scenario` before sharding. Separate processes are
  essential because every scenario changes network and resource globals.
- `TestCheck` discovers and limits test-bearing projects before weighted
  sharding by source bytes, so parallel `--limit N` has exactly the same
  selected project set as sequential `--limit N`.
- The long `ConcurrencyParityTests.runtimeFixturesMatchNativeGuarantees` test
  reads `DYNAMIC_SWIFT_PARITY_SHARD_INDEX` and
  `DYNAMIC_SWIFT_PARITY_SHARD_COUNT`. With neither variable it runs the entire
  manifest, preserving normal focused-test behavior. The gate excludes that
  one test from the main test process and runs its manifest cases in several
  independent prebuilt test-bundle processes. The gate invokes the active
  toolchain's `swiftpm-testing-helper` directly after the one build: concurrent
  `swift test --skip-build` commands still acquire the same SwiftPM workspace
  lock and serialize. Every other test uses that helper's
  `--parallel --num-workers` runner.

Do not shard before filtering or limiting: doing so changes which cases a
bounded run covers. Do not let worker processes update a shared verification
cache. When adding a new parallel board, emit counters whose summed `total`
can be checked against the coordinator's original count.

## Gate stages and resource budget

The gate intentionally uses stages instead of launching every possible worker
at once:

1. one `swift build --build-tests`;
2. the main Swift test runner and concurrency-parity process shards together;
3. corpus and generated API parity together;
4. live-data workers after the corpus has exited.

Live rendering stays separate because deep render graphs retain substantially
more memory. On the 16-logical-core, 48 GB reference machine, a sequential
forced 680-project sweep took 624 seconds and reached 7.30 GB RSS. Process
shards shorten each worker's lifetime, but their heaps overlap; CPU count alone
must never be treated as a safe memory budget.

The default global budget is `min(logicalCPU, 8)`. The test stage splits it in
half between SwiftPM workers and concurrency-parity processes. Corpus and API
parity each receive half while running together. Live receives at most four
workers. A check also caps `--jobs` to its selected item count.

Reference measurements on 2026-07-14:

- the full concurrency/test stage fell from 103 seconds with lock-serialized
  `swift test` children to 41 seconds with four direct prebuilt helpers;
- generated API parity fell from 1.54 seconds to 0.67 seconds with four
  workers;
- a forced 680-project corpus fell from 624 seconds sequential to 195 seconds
  with round-robin workers, then 174 seconds with size-weighted LPT;
- the five-scenario `LiveCheck --jobs 4` run took 430.49 wall seconds and
  445.68 CPU seconds. That near-1:1 ratio is evidence of an indivisible tail,
  not a reason to allocate more live workers.

Treat these as comparison points, not permanent thresholds; corpus contents
and toolchain versions change.

All allocations can be overridden:

| Variable | Controls | Default |
| --- | --- | --- |
| `GATE_JOBS` | Base budget used by the formulas | `min(logicalCPU, 8)` |
| `GATE_TEST_WORKERS` | Swift Testing `--num-workers` for tests other than the long parity test | half the base budget |
| `GATE_PARITY_TEST_WORKERS` | Processes partitioning concurrency parity fixtures | remaining half |
| `GATE_EVAL_WORKERS` | Workers per `ProjectCheck` and `ParityCheck` while those boards overlap | half the base budget |
| `GATE_LIVE_WORKERS` | LiveCheck processes in its isolated stage | `min(base, 4)` |
| `GATE_KEEP_LOGS=1` | Preserve the temporary build/worker logs and print their directory | disabled |

Every worker value must be a positive integer. Setting an override above the
base budget is an explicit request to oversubscribe; the gate does not silently
rewrite it.

Examples:

```sh
Scripts/gate.sh
GATE_JOBS=4 Scripts/gate.sh
GATE_EVAL_WORKERS=2 GATE_LIVE_WORKERS=1 Scripts/gate.sh
GATE_KEEP_LOGS=1 Scripts/gate.sh

.build/debug/ProjectCheck --all --force --jobs 4
.build/debug/ParityCheck --jobs 4
.build/debug/LiveCheck --jobs 2
.build/debug/TestCheck --all --jobs 4
```

## Diagnosing and improving allocation

The gate prints wall time for every stage. For CPU and memory evidence, retain
the logs and wrap either the whole gate or a single board:

```sh
/usr/bin/time -lp Scripts/gate.sh
/usr/bin/time -lp .build/debug/ProjectCheck --all --force --jobs 4
ps -o pid,ppid,%cpu,rss,etime,command -ax | grep -E 'ProjectCheck|ParityCheck|LiveCheck|swift-testing'
```

To inspect load balance directly, run explicit child shards one at a time:

```sh
/usr/bin/time -lp .build/debug/ProjectCheck --all --force \
  --jobs 1 --shard-index 0 --shard-count 4
```

Repeat for indices `0..<4`. This is diagnostic mode: explicit child shards do
not write the full-sweep cache.

Use the evidence as follows:

- Low CPU with stable RSS: raise the worker count for that stage.
- Swap, memory-pressure termination, or superlinear RSS: lower that stage's
  count; start with `GATE_EVAL_WORKERS` or `GATE_LIVE_WORKERS`.
- One weighted shard finishing much later: source bytes are a poor proxy for
  that workload. The next architectural upgrade is a checked-in or
  fingerprinted historical-duration table feeding the same deterministic LPT
  primitive. Do not add project-name scheduling special cases.
- Small filtered runs becoming slower: process startup dominates. Coordinators
  already cap workers to item count; a future policy may add a measured
  minimum-work threshold before spawning.
- Repeated native-twin startup dominating `ParityCheck`: generate one immutable
  native result file in the coordinator and pass its path to children. Keep the
  file read-only and fingerprinted; do not share mutable dictionaries.
- SwiftPM planning or build locks dominating test shards: keep the one-build
  invariant and verify that the gate still launches the active toolchain's
  prebuilt test helper directly. Never allow parallel workers to compile into
  the same scratch directory.

An indivisible live scenario can still determine the live-stage wall time.
Profiling on 2026-07-14 showed `achnbrowser-items-ui` spending its tail in one
structural decode of 1,191 JSON elements. Adding scenario workers cannot split
that `MainActor` eval. Treat it as evaluator/decode optimization work; do not
hide it with a scenario-name skip, reduced fixture, or traversal cutoff.

Any replacement algorithm must retain deterministic coverage, per-process
semantic isolation, bounded resource use, full exit-status propagation, and an
aggregate count check. Benchmark both wall time and peak RSS; optimizing only
one can make the gate less usable on smaller machines.
