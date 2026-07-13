# Task Observatory

A forward-looking SwiftUI demo for the interpreter's Task architecture. It
launches three detached workers, records suspension and resumption events,
cancels one task, and has two independent waiters consume the same
`Task.value`.

The execution-lane probe intentionally distinguishes `Main thread` from
`Worker pool`. With the current cooperative runtime it documents today's
behavior; after physical parallelism is implemented, the same UI can be used
to retest worker-pool execution and overlapping progress without redesigning
the example.

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

- Atlas, Beacon, and Comet make independent progress.
- Event rows report worker-pool execution where expected.
- Cancelling Beacon does not cancel Atlas or Comet.
- Both waiters resume with Comet's single `orbit-42` result.
- Restarting cancels the previous generation without leaking old events.
