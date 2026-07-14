# Task Observatory

A SwiftUI demo for the interpreter's Swift Concurrency architecture. One run
combines structured and unstructured tasks instead of treating every unit of
work as an independent detached task:

- **Atlas** starts two `async let` bindings and joins their results.
- **Beacon** wraps a heartbeat loop in `withTaskCancellationHandler`, checks
  cancellation explicitly, and demonstrates cancellation interrupting sleep.
- **Comet** dynamically fans four child operations out through
  `withTaskGroup`, consumes them in completion order with `group.next()`, and
  reduces their values to one shared result.
- A high-priority task and a utility task both await the same background
  Comet handle through `Task.value`.

Every simulated delay uses `try await Task.sleep(for:)`. Sleep suspends the
task and releases the cooperative executor; it does not block a thread. The
workers also exercise explicit task priorities, `Task.checkCancellation()`,
`Task.isCancelled`, `Task.yield()`, `@MainActor` UI handoffs, and `@concurrent`
nonisolated worker methods.

The execution-lane probe distinguishes `Main thread` from `Worker pool`.
Swift concurrency does not promise one thread per task, and the interpreter's
current runtime is cooperative. The lane is therefore an observation, not a
scheduling assertion; the same dashboard can be reused when physical
parallelism is introduced.

Run it from the repository root:

```sh
swift run DynamicSwiftUIDemo --project Examples/TaskObservatory
```

Render deterministic light and dark verification snapshots with:

```sh
swift run DynamicSwiftUIDemo --project Examples/TaskObservatory \
  --render-png /tmp/task-observatory.png --size 980x720 --appearance dark
```

Retest checklist:

- Atlas's two child sleeps overlap and both bindings are joined.
- Comet receives four group results and reduces them to `orbit-10`.
- Cancelling Beacon fires `onCancel`, interrupts `Task.sleep`, and does not
  cancel Atlas or Comet.
- Both waiters resume with Comet's single `orbit-10` result.
- Event rows report the observed execution lane at each suspension boundary.
- Restarting cancels the previous generation without leaking old events.
