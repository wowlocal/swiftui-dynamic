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
  Each shard emits exactly one `@@concurrency-parity-summary` JSON marker with
  its selected and completed case IDs/repetition counts plus a per-case digest
  of the sorted native observations. The gate rejects missing or duplicate
  markers, shard-index/count mismatches, incomplete work, overlapping
  selections, or a union different from the runtime manifest. Interpreted
  repetitions run in bounded fresh child processes, so a source deadlock is a
  case timeout and process-global state cannot leak into the next observation.
- The official swiftlang executable allowlist is a parameterized Swift Testing
  test with one argument per SHA-pinned fixture. Native compilation and process
  execution are explicitly nonisolated, while only the interpreter half hops
  back to MainActor. The ordinary prebuilt test worker pool can therefore
  distribute native compilers concurrently without making interpreter state
  nonisolated or hiding all fixtures inside one serialized test body.

Do not shard before filtering or limiting: doing so changes which cases a
bounded run covers. Do not let worker processes update a shared verification
cache. When adding a new parallel board, emit counters whose summed `total`
can be checked against the coordinator's original count.

## Fast iteration loop

Do not run the closing gate after every edit. Build the test bundle once, then
run focused selections directly without re-entering SwiftPM:

```sh
swift build --build-tests
Scripts/run-prebuilt-tests.sh --no-parallel --filter 'ARCSemanticsTests'
Scripts/run-prebuilt-tests.sh --parallel --num-workers 6 \
  --filter 'SwiftUpstreamParityTests'
Scripts/run-focused-parity.sh protocol-async-sequence-cancellation --jobs 4
Scripts/run-concurrency-iteration.sh CASE_ID TEST_FILTER --skip-build \
  --methodology-filter 'RELEVANT_METHOD_TEST|milestoneAcceptanceMatrixIsCompleteAndConsistent'
```

Independent read-only selections may run concurrently because they do not
contend for the SwiftPM workspace lock; suites that intentionally share an
external fixture still need their documented isolation. Rebuild once after
production or test source changes. Use the full source-bound gate only at an
integration or milestone boundary.

The concurrency-iteration runner keeps the complete methodology suite as its
safe default. During repeated RED/GREEN edits, pass one regular expression that
selects the affected surface-disposition test plus the acceptance-matrix test.
Run the command once without `--methodology-filter` before committing. This
keeps the semantic guard in the inner loop without re-running unrelated API
disposition checks on every edit.

The focused parity runner is specifically for the one-case semantic loop. It
selects exactly one runtime fixture from the manifest, divides that fixture's
declared repetitions among independent prebuilt test processes, and validates
one receipt from every worker. The aggregate is RED for an unknown/non-runtime
case, an invalid worker count, a missing or duplicate receipt, a malformed
digest, a mismatched case selection, or any repetition total other than the
manifest's exact count. The ordinary closing gate never sets the focused
repetition override and continues to require every case and every manifest
repetition through its separate whole-board validator.
Workers receive equal-sized repetition slices so exact-case native digests can
also be compared across processes. If `--jobs` does not divide the manifest
count, the runner uses the largest lower divisor (for example, 20 repetitions
with `--jobs 6` use five workers).

## Gate stages and resource budget

The gate intentionally uses stages instead of launching every possible worker
at once:

1. one `swift build --build-tests`;
2. the main Swift test runner and concurrency-parity process shards together;
3. corpus and generated API parity together;
4. live-data workers after the corpus has exited.

Before the build stage, the gate acquires one exclusive lease under the
repository's git common directory. Linked worktrees therefore share the same
host-level closing-gate budget. A second gate writes a bounded RED receipt and
exits before build instead of competing for CPU and turning per-probe liveness
deadlines into false semantic failures. The owner PID, worktree, and start time
make the conflict actionable; a dead owner's lock is reclaimed, and normal or
signalled cleanup releases the lease. Focused prebuilt-test lanes do not take
this lock and may still run concurrently.

Live rendering stays separate because deep render graphs retain substantially
more memory. On the 16-logical-core, 48 GB reference machine, a sequential
forced 680-project sweep took 624 seconds and reached 7.30 GB RSS. Process
shards shorten each worker's lifetime, but their heaps overlap; CPU count alone
must never be treated as a safe memory budget.

The default global budget is `min(logicalCPU, 8)`. The test stage gives one
quarter to ordinary Swift Testing workers and the remainder to
concurrency-parity processes. The latter is now the long lane: 135 cases own
2,662 fresh-process repetitions, while adding ordinary test workers stops
helping much earlier. Corpus and API parity each receive half while running
together. Live receives at most four workers. A check also caps `--jobs` to its
selected item count.

Reference measurements on 2026-07-14:

- the full concurrency/test stage fell from 103 seconds with lock-serialized
  `swift test` children to 41 seconds with four direct prebuilt helpers;
- the 23-case official swiftlang executable board fell from 23.03 seconds in
  one serialized test to 5.24 seconds with four prebuilt Swift Testing workers;
- generated API parity fell from 1.54 seconds to 0.67 seconds with four
  workers;
- a forced 680-project corpus fell from 624 seconds sequential to 195 seconds
  with round-robin workers, then 174 seconds with size-weighted LPT;
- the five-scenario `LiveCheck --jobs 4` run took 430.49 wall seconds and
  445.68 CPU seconds. That near-1:1 ratio is evidence of an indivisible tail,
  not a reason to allocate more live workers.

A 2026-07-17 focused measurement on the 20-repetition
`protocol-async-sequence-cancellation` case took 14.88 seconds in one process
and 4.73 seconds with four repetition workers. Both executions compiled real
Swift and completed all 20 interpreted fresh-process observations; the latter
traded additional aggregate CPU for a 3.1x inner-loop wall-time reduction.
The original 39-test methodology suite took 12.40 seconds with `--no-parallel`
and 12.65 seconds with four workers: parallel workers could not compensate for
repeated whole-source scans. Its whole-board validator now captures large
subprocess output in files rather than calling `waitUntilExit()` before
draining a pipe; at 138 runtime cases the JSON receipt can fill the pipe buffer
and turn an otherwise sub-second test into an unbounded wait.

At 41 tests, two accounting checks had grown to about 5.35 seconds each because
every cited test name rescanned the joined 2.1 MB Swift test source. Building a
test-function-name set once per check reduced the complete serial methodology
lane from 14.99 to 4.97 seconds. The concurrency-iteration helper separates the
three tests that invoke `gate.sh` and runs the other 38 with four prebuilt
workers. Each gate-contract test has its own prebuilt process: the toolchain
and accounting failures exit before lock acquisition, while the lock-conflict
test supplies a unique temporary lock. This preserves the lock contract while
letting all three overlap. The ordinary 38-test lane takes 0.88 seconds; the
three gate processes take about 2.54 seconds together instead of 3.98 seconds
serially, so they remain the honest critical path. The runner prints every
lane's elapsed time to make future regressions visible.
For the 20-repetition checked-throwing-continuation slice on the same reference
host, a warm-bundle iteration with the two relevant methodology checks took
5.3 seconds; the pre-commit form with all 39 methodology tests took 12.9
seconds. Rebuilding the test bundle after source changes remained a separate
13-second incremental cost.

The runtime manifest subsequently grew from the early benchmark to 135 cases
and 2,662 isolated repetitions. A 2026-07-17 closing receipt showed the
four-shard parity lane still running long after the ordinary test worker pool
had exited. The default test-stage split was therefore changed from 4+4 to
2 ordinary workers + 6 parity shards on the eight-worker budget, without
raising peak process count. Closing gates from separate worktrees should not
overlap on one host: CPU contention lengthens both receipts, makes their stage
timings useless, and can starve bounded native probes. The git-common-dir lease
now enforces that rule. Lane iterations use focused prebuilt tests; the primary
worktree runs the one full gate after integration.

Two subsequent source-bound RED receipts exposed a narrower load-sensitive
boundary: the native binaries for `task-priority-escalation` and its transitive
variant exceeded their original five-second process deadline while the main
compiler-heavy suite and six parity shards were active. Both cases then passed
20/20 simultaneously in two four-worker focused boards with unchanged exact
digests. Their authored process deadline is therefore 15 seconds. This changes
only the bounded liveness envelope under gate load; exact output, repetitions,
native/interpreter comparison, and the 30-minute whole-stage deadline are
unchanged.

Treat these as comparison points, not permanent thresholds; corpus contents
and toolchain versions change.

All allocations can be overridden:

| Variable | Controls | Default |
| --- | --- | --- |
| `GATE_JOBS` | Base budget used by the formulas | `min(logicalCPU, 8)` |
| `GATE_TEST_WORKERS` | Swift Testing `--num-workers` for tests other than the long parity test | one quarter of the base budget, at least one |
| `GATE_PARITY_TEST_WORKERS` | Processes partitioning concurrency parity fixtures | the remaining test-stage budget |
| `GATE_EVAL_WORKERS` | Workers per `ProjectCheck` and `ParityCheck` while those boards overlap | half the base budget |
| `GATE_LIVE_WORKERS` | LiveCheck processes in its isolated stage | `min(base, 4)` |
| `GATE_BUILD_TIMEOUT_SECONDS` | Whole build-stage deadline | `1800` |
| `GATE_TEST_TIMEOUT_SECONDS` | Main-test plus concurrency-shard deadline | `1800` |
| `GATE_EVAL_TIMEOUT_SECONDS` | Corpus plus API-parity deadline | `1800` |
| `GATE_LIVE_TIMEOUT_SECONDS` | Live-stage deadline | `1800` |
| `GATE_CHILD_TIMEOUT_SECONDS` | Deadline passed to process-sharding check tools | `1500` |
| `GATE_TERMINATION_GRACE_SECONDS` | TERM grace before process-tree KILL | `5` |
| `GATE_KEEP_LOGS=1` | Preserve the temporary build/worker logs and print their directory | disabled |
| `GATE_RECEIPT_PATH` | Machine-readable closing receipt | `.build/gate-receipt.json` |
| `GATE_LOCK_DIRECTORY` | Override the cross-worktree exclusive closing-gate lease path; intended for isolated methodology tests | shared git common directory |
| `GATE_EXPECTED_TOOLCHAIN_FINGERPRINT` | Require a pinned combined build/native/SDK fingerprint; unset records without pinning | unset |
| `GATE_CAPABILITY_INVENTORY_INPUT_PATH` / `GATE_CAPABILITY_STATUS_INPUT_PATH` | Override only the physical accounting inputs for fail-closed negative controls; the receipt records both canonical and physical paths | checked-in manifests |

Every worker value must be a positive integer. Setting an override above the
base budget is an explicit request to oversubscribe; the gate does not silently
rewrite it.

Examples:

```sh
Scripts/gate.sh
GATE_JOBS=4 Scripts/gate.sh
GATE_EVAL_WORKERS=2 GATE_LIVE_WORKERS=1 Scripts/gate.sh
GATE_KEEP_LOGS=1 Scripts/gate.sh
GATE_TEST_TIMEOUT_SECONDS=900 Scripts/gate.sh
GATE_RECEIPT_PATH=/tmp/gate-receipt.json Scripts/gate.sh
GATE_EXPECTED_TOOLCHAIN_FINGERPRINT="$PINNED_TOOLCHAIN_FINGERPRINT" Scripts/gate.sh

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

## Closing receipt and timeout policy

Every stage and process worker has a finite wall-clock deadline. Timeout
handling snapshots the process tree, sends TERM, waits the configured grace
period, sends KILL to survivors, and returns RED. Every shell identity combines
the PID with a captured process-start token and is revalidated before each
signal, so PID reuse cannot redirect escalation. The gate watchdogs bound the
build, test discovery and execution, evaluation boards, and live work;
`ParallelCheckRunner`
independently bounds the worker processes launched by each check executable.

The gate writes its receipt on both GREEN and RED exit before deleting
temporary logs. It recomputes the commit and dirty-worktree fingerprint at
completion; any drift during verification turns an otherwise GREEN run RED.
The JSON receipt records both source snapshots, parity/acceptance-manifest
digests and parity counts, plus the generated concurrency-inventory and
authored-status digests, pin result, scope flag, and resolved status counts.
Malformed accounting or an SDK inventory/status pin mismatch blocks the build
and produces RED. The receipt also records the build/test Swift driver,
native-oracle compiler, SDK/target versions, worker/deadline configuration,
per-stage status/duration, board summaries, parity-shard
validation/native-observation digests, and a digest of the temporary evidence
logs. RED receipts also retain stage exit statuses, timeout messages, bounded
log tails, parity-validator diagnostics, interruptions, and source-drift
details so the failure remains actionable after temporary logs are removed.
Local runs print the
receipt path; CI retains that file as the auditable closing artifact. Temporary
logs remain optional because their digest and aggregate verdict survive in the
receipt. A nominally green run becomes RED if the required receipt cannot be
validated and installed atomically; if receipt creation itself fails, the gate
keeps the temporary logs automatically.
