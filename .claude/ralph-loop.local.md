---
active: true
iteration: 667
session_id: 16c0acb3-9222-45e5-998b-0019f47e4ece
max_iterations: 0
completion_promise: null
started_at: "2026-07-08T21:54:06Z"
---

Read LOOP.md and execute exactly one iteration of its algorithm. Follow LOOP.md exactly - it defines the health check, the measurement, how to pick the single biggest failure class, how to fix it, the regression coverage requirement, the commit, and the progress log update.

MISSION CHANGE (user directive 2026-07-11, supersedes your prior queue memory):
re-read the "PRIMARY TARGET: Food Truck" section at the TOP of LOOP.md and work
IT first — bootstrap `swift run FoodTruckCheck` if it doesn't exist yet, then
climb its rung ladder. The FoodTruck target OUTRANKS TestCheck/ProjectCheck/
LiveCheck classes; those boards are regression backstops only (never regress,
never weaken tests). The native twin already exists at
Examples/FoodTruckNativeTwin (swift run FoodTruckNativeTwin --out DIR). Use
`Scripts/gate.sh` as the closing gate — one build, all boards parallel (~3 min,
replaces your serial ~20-min chain); ProjectCheck --all self-caches.
