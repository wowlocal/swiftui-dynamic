# FoodTruck R3 — function parity protocol

R3 verifies that the app FUNCTIONS identically: the same state mutation on
both sides must produce the same re-rendered screen. SwiftUI is view =
f(state), so R3 rides on R2's capture machinery — mutate through the
model's OWN public API, re-capture, diff.

**Protocol decision: model-API mutation, NOT event injection.** Injecting
NSEvents into the twin tests AppKit hit-testing, not the app; and the
interpreter's click machinery already exists (HeadlessVerifier actions)
for the interp side's own click coverage. The PARITY check is the pure
function: `capture(mutate(model))` must match twin-vs-interp exactly like
R2's static screens. Clicks stay in FoodTruckCheck's interp-side rungs;
cross-side parity uses the API below.

Each scenario: run on BOTH sides → re-capture the named screen →
pixel-ae with that screen's R2 floor. A scenario passes only if the
POST-MUTATION diff is within floor AND the mutation visibly changed the
screen (guard against absorbed no-ops: pre != post on both sides).

## Checklist (the model API is the contract — verified against
FoodTruckKit sources 2026-07-11)

1. donut-rename — `model.updateDonut(id: donuts[0].id, to: renamed)`
   (copy with `name = "Parity Deluxe"`) → re-capture `donuts` gallery:
   new name renders; `donut-view` of that donut renders it too.
2. order-completes — `model.markOrderAsCompleted(id: firstPlacedOrder)`
   → re-capture `orders`: status column/count updates.
3. order-steps — `order.markAsPreparing()` then `markAsComplete()` via
   `model.orderBinding(for:)` → each step re-renders `orders`
   consistently on both sides.
4. popularity-moves — bulk-complete N orders containing donut X →
   `donuts(sortedBy: .popularity(.month))` order changes → re-capture
   `donuts` (grid order) and `card-donuts`.
5. nav-selection — set the sidebar `Panel` selection (truck → orders →
   donuts) in the probe shell → `content` re-capture shows the right
   detail each time (interp already proves clicks in FoodTruckCheck;
   parity checks the SELECTION → DETAIL function).
6. state-survives-nav — scenario 1's rename, then nav away and back
   (scenario 5 machinery) → the rename still renders (@StateObject
   identity holds through navigation on both sides).

## Native-baseline rules (unchanged doctrine)
- The twin runs the SAME scenario via a `--scenario <name>` flag
  (mutations coded against FoodTruckKit's public API only).
- Expectations are the twin's post-mutation captures — never
  hand-written.
- A scenario that can't run headless natively is environmental, not a
  rung (none of the six above have that problem — all pure model API).
- Per-screen fuzz floors from R2 carry over; they never widen.
