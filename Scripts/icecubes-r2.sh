#!/bin/zsh
# Capture compiled Catalyst and interpreted IceCubes screens from the same
# recorded Mastodon bytes, then enforce each screen's exact per-pixel AE.
#
# Determinism contract: every scored screen is captured TWICE per side and the
# two passes must be pixel-identical (AE 0, no fuzz) before the board scores
# anything. A floor delta can then only mean interpreter fidelity moved —
# never spinner phase, settle timing, or machine load (the 2026-07-30 noise
# band was ~17-33k AE, larger than several committed ratchet ticks).
set -u
cd "$(dirname "$0")/.." || exit 2

ROOT="$PWD"
FIXTURES="$ROOT/Fixtures/mastodon-public-timeline"
# Worktree-local by default so concurrent lanes never clobber each other's
# captures; the per-screen stdout lines carry the concrete paths.
TWIN_DIR="${ICECUBES_R2_TWIN_DIR:-$ROOT/.build/icecubes-r2-captures/native-twin}"
INTERP_DIR="${ICECUBES_R2_INTERP_DIR:-$ROOT/.build/icecubes-r2-captures/interpreted}"
TWIN_REPEAT_DIR="$TWIN_DIR-repeat"
INTERP_REPEAT_DIR="$INTERP_DIR-repeat"
# 2026-07-16T12:00:00Z, immediately after the recorded fixture was captured.
FROZEN_NOW=1784203200
CLOCK_DIR="$ROOT/Examples/IceCubesNativeTwin/.build/frozen-clock"
INTERP_SCRATCH_PATH="${ICECUBES_R2_SCRATCH_PATH:-$ROOT/.build/icecubes-r2-product}"
INTERP_BUILD_DIR="$INTERP_SCRATCH_PATH/arm64-apple-ios-macabi/debug"
INTERP_BINARY="$INTERP_BUILD_DIR/IceCubesCheck"
INTERP_APP="$INTERP_BUILD_DIR/IceCubesCheck.app"
INTERP_EXECUTABLE="$INTERP_APP/Contents/MacOS/IceCubesCheck"
# The scored screens, in capture order. ONE list: three copies drifted apart
# is how a screen ends up captured but never scored, which reads exactly like
# a screen that converged.
R2_SCREENS=(timeline status-detail account-header media tags-list media-browser
  trending-timeline trending-links instance-info display-settings
  hashtag-timeline)
mkdir -p "$TWIN_DIR" "$INTERP_DIR" "$TWIN_REPEAT_DIR" "$INTERP_REPEAT_DIR"
for capture_dir in \
  "$TWIN_DIR" "$TWIN_REPEAT_DIR" "$INTERP_DIR" "$INTERP_REPEAT_DIR"; do
  rm -f "$capture_dir/timeline.json"
  for screen in "${R2_SCREENS[@]}"; do
    # `.tree` is cleared with the rest: a geometry dump left over from an
    # earlier run is indistinguishable from this run's, and a stale one is
    # read as evidence about the capture sitting next to it.
    rm -f "$capture_dir/$screen.png" "$capture_dir/$screen.log" \
      "$capture_dir/$screen.tree"
  done
done

echo "── native IceCubes twin ──"
(
  cd Examples/IceCubesNativeTwin || exit 2
  ./build.sh
) || exit 2

run_twin_screen() {
  local screen="$1"
  local twin_out="$2"
  (
    cd Examples/IceCubesNativeTwin || exit 2
    ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
    DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
    .build/arm64-apple-ios-macabi/debug/IceCubesNativeTwin.app/Contents/MacOS/IceCubesNativeTwin \
      --out "$twin_out" --fixtures "$FIXTURES" --screen "$screen" \
      -ApplePersistenceIgnoreState YES
  )
}

# Only a PROVEN-REPRODUCIBLE capture may be scored: each side captures twice
# and the pair must match exactly. A bounded number of fresh pairs absorbs
# transient window-server perturbation from unrelated lane activity on the
# same machine (`drawHierarchy` snapshots through the compositor); persistent
# divergence — a live animation, a settle bug — fails every attempt and exits
# loudly. The retry lives HERE, capped: never loop the script itself until a
# red goes green, and never answer this red by moving a floor.
#
# A capture process that DIES is retried by the same bounded loop rather than
# aborting the board on first sight. Measured 2026-08-03: a full gate lost the
# interpreted account-header capture to a launch-time death that wrote a
# zero-byte log, while the same screen captured cleanly 8/8 at idle and in a
# solo board run on the same binary — a transient the window server loses, not
# a divergence. Retrying cannot weaken the metric: the pair still has to match
# at AE 0 before anything is scored, so a retried capture can only produce the
# same pixels or fail again. Persistent death exhausts the attempts and exits
# loudly with the real status.
twin_reproducible=0
twin_failure="diverged"
for attempt in 1 2 3; do
  twin_diverged=0
  for screen in "${R2_SCREENS[@]}"; do
    run_twin_screen "$screen" "$TWIN_DIR"
    twin_status=$?
    if (( twin_status == 0 )); then
      run_twin_screen "$screen" "$TWIN_REPEAT_DIR"
      twin_status=$?
    fi
    if (( twin_status != 0 )); then
      echo "twin $screen capture failed with status $twin_status" \
        "(attempt $attempt)" >&2
      twin_diverged=1
      twin_failure="died"
      break
    fi
    determinism_line="$(xcrun swift Scripts/pixel-ae.swift \
      "$TWIN_DIR/$screen.png" "$TWIN_REPEAT_DIR/$screen.png")"
    if (( $? != 0 )); then
      echo "twin $screen capture pair diverged (attempt $attempt: $determinism_line)"
      twin_diverged=1
      twin_failure="diverged"
      break
    fi
  done
  if (( twin_diverged == 0 )); then
    twin_reproducible=1
    break
  fi
done
if (( twin_reproducible == 0 )); then
  if [[ "$twin_failure" == died ]]; then
    echo "twin CAPTURE-DEATH: no capture survived 3 attempts —" \
      "fix the capture, not the floor" >&2
  else
    echo "twin CAPTURE-NONDETERMINISM: no reproducible capture pair in 3" \
      "attempts — fix the capture, not the floor" >&2
  fi
  exit 2
fi

# ONE FROZEN SOURCE OF WALL TIME IS NOT A FROZEN CLOCK, and the epoch check
# below cannot tell the difference. `Date()` is pinned by a dyld interposer, so
# `clockEpoch` reads the frozen instant and passes — while
# `Date.timeIntervalSinceNow` computes its own "now" INSIDE Foundation, never
# crossing an image boundary, and so kept reading the real clock. IceCubes
# renders exactly that on the settings screens (`ServerDate()` is newer than a
# day, so `relativeFormatted` takes the `Duration.seconds(-…timeIntervalSinceNow)`
# branch): the example post drew "527h" and ticked once an HOUR, with this
# script green the whole time because it only ever asked about `Date()`.
#
# Both sides now report that reading and the board refuses anything but an
# exact zero. The next unpinned wall-clock source fails an exit code here
# instead of waiting for a reviewer to notice a timestamp that looks plausible.
assert_frozen_relative_clock() {
  local label="$1" metadata="$2" key="$3"
  if ! jq -e --arg k "$key" '.[$k] == 0' "$metadata" >/dev/null; then
    echo "$label relative clock is not frozen: $key is" \
      "$(jq -r --arg k "$key" '.[$k]' "$metadata"), wanted exactly 0 — a" \
      "wall-clock source is leaking past the frozen instant" >&2
    exit 2
  fi
}

OBSERVED_CLOCK="$(jq -r '.clockEpoch' "$TWIN_DIR/timeline.json")"
if [[ "$OBSERVED_CLOCK" != "$FROZEN_NOW" ]]; then
  echo "native frozen clock mismatch: wanted $FROZEN_NOW, got $OBSERVED_CLOCK" >&2
  exit 2
fi
assert_frozen_relative_clock native "$TWIN_DIR/timeline.json" relativeClockDrift
if ! jq -e '
  .screenFixtures
  | [
      .status,
      .statusContext,
      .account,
      .featuredTags,
      .accountStatuses,
      .familiarFollowers
    ]
  | length == 6 and all(.[]; type == "string" and length > 0)
' "$TWIN_DIR/timeline.json" >/dev/null; then
  echo "native screen fixture metadata is missing or malformed" >&2
  exit 2
fi
screen_fixture_names=(
  "${(@f)$(jq -r '
    .screenFixtures
    | [
        .status,
        .statusContext,
        .account,
        .featuredTags,
        .accountStatuses,
        .familiarFollowers
      ][]
  ' "$TWIN_DIR/timeline.json")}"
)
for fixture_name in "${screen_fixture_names[@]}"; do
  if [[ ! -f "$TWIN_DIR/$fixture_name" ]]; then
    echo "native screen fixture is missing: $fixture_name" >&2
    exit 2
  fi
done

echo "── interpreted IceCubes ──"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
IOS_FRAMEWORKS="$SDK/System/iOSSupport/System/Library/Frameworks"
IOS_LIBS="$SDK/System/iOSSupport/usr/lib"
xcrun swift build \
  --scratch-path "$INTERP_SCRATCH_PATH" \
  --product IceCubesCheck \
  --triple arm64-apple-ios18.0-macabi \
  -Xcc -target -Xcc arm64-apple-ios18.0-macabi \
  -Xswiftc -target -Xswiftc arm64-apple-ios18.0-macabi \
  -Xswiftc -F -Xswiftc "$IOS_FRAMEWORKS" \
  -Xswiftc -I -Xswiftc "$IOS_LIBS/swift" \
  -Xlinker -F -Xlinker "$IOS_FRAMEWORKS" \
  -Xlinker -L -Xlinker "$IOS_LIBS" || exit 2
mkdir -p "$INTERP_APP/Contents/MacOS"
cp "$INTERP_BINARY" "$INTERP_EXECUTABLE"
cp "$ROOT/Scripts/IceCubesCheck-Info.plist" \
  "$INTERP_APP/Contents/Info.plist"
codesign --force --sign - "$INTERP_APP" >/dev/null || exit 2

capture_interpreted_screen() {
  local screen="$1"
  local out_dir="$2"
  local native_args=()
  # Mirrors IceCubesCaptureScreen.needsNativeFixtures: only the screens the
  # TWIN chose a status and prepared endpoints for read its output directory.
  # Stated as the SHORT side of that split — the screens that DO need them —
  # so adding a screen built from the checked-in recordings cannot silently
  # drift this condition away from the Swift enum.
  if [[ "$screen" == status-detail || "$screen" == account-header ]]; then
    native_args=(--native-fixtures "$TWIN_DIR")
  fi
  ICECUBES_FROZEN_NOW="$FROZEN_NOW" \
  SWIFT_DETERMINISTIC_HASHING=1 \
  DYLD_INSERT_LIBRARIES="$CLOCK_DIR/libIceCubesFrozenClock-macabi.dylib" \
  "$INTERP_EXECUTABLE" --capture "$out_dir" --screen "$screen" \
    "${native_args[@]}" -ApplePersistenceIgnoreState YES \
    > "$out_dir/$screen.log" 2>&1
}

# Captures run STRICTLY SERIALLY. Measured 2026-07-30: three parallel capture
# processes contend for the window server, `drawHierarchy` takes a different
# snapshot path per run, and two passes of the same binary on the same
# fixtures differ by 141k+ AE (±1-per-channel wobble plus spinner phase);
# serialized, four consecutive captures are pixel-exact. Do not restore the
# `&` fan-out without also proving the reproducibility gate below stays green.
capture_reproducible_interpreted_screen() {
  local screen="$1"
  local attempt determinism_line capture_status
  local failure="diverged"
  for attempt in 1 2 3; do
    local capture_died=0
    for interp_out in "$INTERP_DIR" "$INTERP_REPEAT_DIR"; do
      capture_interpreted_screen "$screen" "$interp_out"
      capture_status=$?
      if (( capture_status != 0 )); then
        cat "$interp_out/$screen.log"
        echo "interpreted $screen capture failed with status" \
          "$capture_status (attempt $attempt)" >&2
        capture_died=1
        failure="died"
        break
      fi
    done
    if (( capture_died )); then
      continue
    fi
    determinism_line="$(xcrun swift Scripts/pixel-ae.swift \
      "$INTERP_DIR/$screen.png" "$INTERP_REPEAT_DIR/$screen.png")"
    if (( $? == 0 )); then
      return 0
    fi
    failure="diverged"
    echo "interpreted $screen capture pair diverged (attempt $attempt: $determinism_line)"
  done
  if [[ "$failure" == died ]]; then
    echo "interpreted $screen CAPTURE-DEATH: no capture survived 3" \
      "attempts — fix the capture, not the floor" >&2
  else
    echo "interpreted $screen CAPTURE-NONDETERMINISM: no reproducible capture" \
      "pair in 3 attempts — fix the capture, not the floor" >&2
  fi
  exit 2
}

for screen in "${R2_SCREENS[@]}"; do
  capture_reproducible_interpreted_screen "$screen"
  cat "$INTERP_DIR/$screen.log"
done

INTERP_OBSERVED_CLOCK="$(jq -r '.interpretedClockEpoch' "$INTERP_DIR/timeline.json")"
if [[ "$INTERP_OBSERVED_CLOCK" != "$FROZEN_NOW" ]]; then
  echo "interpreted frozen clock mismatch: wanted $FROZEN_NOW, got $INTERP_OBSERVED_CLOCK" >&2
  exit 2
fi
assert_frozen_relative_clock interpreted "$INTERP_DIR/timeline.json" \
  interpretedRelativeClockDrift

echo "── R2 AE board ──"
# Ratchet floors — enforced, committed baselines (AUDIT-2026-07-23-R2-stall.md
# rec #2, mirroring Scripts/foodtruck-r3.sh). The timeline remains the LOOP R2
# metric and exact at zero. Every other screen is measured independently so a
# green timeline cannot hide regressions or unmeasured screen gaps — and their
# SUM is the pixel half of the north star (LOOP-ICECUBES §13), so the honest
# way to keep it meaningful once the scored screens converge is to score the
# app's next screen, not to read three zeroes as a finished app.
typeset -A R2_FLOORS
R2_FLOORS=(
  timeline 0
  status-detail 0
  account-header 0
  media 0
  # Was 4. Two of those pixels were never interpreter fidelity: they were the
  # twin encoding its capture as Display P3 16-bit while IceCubesCheck encoded
  # sRGB 8-bit, so one side dithered a flat fill the other represented exactly.
  # Both sides now pin `preferredRange`, and the comparator refuses to score a
  # pair that disagrees on its encoding.
  #
  # THE REMAINING 2 ARE CLASSIFIED, AND NO RENDERER FIX IS OWED — recorded here
  # so they are not re-distilled a third time. `Scripts/pixel-diff-map.swift`
  # over a reproducible pair (each side AE 0 against its own repeat) reports:
  # two spatially separate 1x1 clusters, x 860 y 627 and x 857 y 638; MAGNITUDE
  # max 1 mean 1.00 of 255; EDGE 2 of 2 differing px sit on a twin edge and 0 in
  # any flat region; CHANNELS 0 neutral, 2 channel-skewed. Both sides therefore
  # drew the SAME shapes in the SAME places in the SAME colours and rounded the
  # antialiased coverage blend one level apart on two pixels. That is the
  # EDGE-BLEND class the map's own header warns is not distillable: an
  # in-process bitmap micro-twin compares rendered output and so cannot express
  # a compositing rounding difference at all. Reading it as a content
  # divergence is how a converged screen gets re-distilled with nothing to
  # find. This floor stays at 2 until the comparator's rasterization question
  # is answered, and it is NOT evidence of an interpreter gap.
  tags-list 2
  # ACKNOWLEDGED tags-list: two pixels of an anti-aliased edge blend, owing no
  # renderer fix — both sides draw the same edge and differ only in how the
  # compositor rounded one sub-pixel pair. The marker exempts this screen from
  # the STALL series ONLY; the floor above is still enforced, so it cannot
  # regress, and the headline still prints it. Delete this line to re-arm the
  # detector on this screen.
  # Was 367681 — the whole image block, behind a UIKit hosting stack that
  # stopped at a different statement every iteration (representable
  # conformance, then the generic hosting controller, then `.view`'s
  # optionality, then `autoresizingMask`, then `addSubview`). The last link was
  # not in that chain at all: an SDK parameter spelled `any View` refused every
  # value SwiftUI builds, so `UIHostingController(rootView:)` fell to its
  # payload-less stub and `.view` handed `addSubview` a typed inert `UIView`.
  # With a native view answering the View existential it satisfies, the image
  # draws and the cliff pays out.
  #
  # Was 18929 — the surrounding container, absorbed from `.scrollPosition(id:)`,
  # whose interface declares `Binding<(some Hashable)?>`: an opaque parameter
  # written IN PLACE inside a compound type, a third spelling BridgeGen
  # specialized in neither of its two paths. Now specialized like the named
  # generic it is sugar for, onto the carrier the wrapper projections already
  # drive.
  #
  # Was 1136 — `MediaUIShareLink`'s `ShareLink(item:preview:)`. ONE failure
  # that read as three: `Scripts/pixel-diff-map.swift` put the 1136 AE in three
  # 25x23 boxes, and the first two were pure ~3px SHIFTS of correct glyphs,
  # because toolbar items are trailing-aligned and the failing button's wrong
  # width displaced its neighbours. Two links: `SharePreview<Image, Icon>` is a
  # compound over TWO constrained generics, which BridgeGen had no spelling
  # for; and once `preview:` was typed at an instantiation, the leading-dot
  # `.init(…)` looked that whole spelling up in a table keyed by nominal.
  #
  # The other diagnostic this screen still prints is NOT a pixel: an absorbed
  # `.quickLookPreview` leaves its receiver rendering, and the info button it
  # decorates is byte-identical on both sides. It was named as a blocker by
  # prose; the pixels acquit it.
  media-browser 0
  # NEW SCREEN, entering at its first measured value — this is a measurement
  # that did not exist before, not a regression of one that did. The six
  # screens above are unchanged (2 AE, all of it tags-list).
  #
  # Why it is worth scoring: every timeline pixel already on this board comes
  # from a harness `StatusesFetcher` handed decoded fixture statuses, on BOTH
  # sides. The app's own `TimelineView` over its own `TimelineViewModel` — the
  # fetch, the state machine, the datasource, the toolbar — had never been
  # compared to the twin at all. `RouterDestination.trendingTimeline` is the
  # one spelling of it the unauthenticated app can drive end to end
  # (`Trends.statuses` is public, and `isCacheEnabled` is false on all three
  # of its terms, so nothing touches disk).
  #
  # What the number is made of, RE-MEASURED on this tree rather than carried
  # over. The screen's history is three states, and only the last one is a
  # floor: one error label at 389990 until `ToolbarSpacer` became constructible
  # (d10c6838); then the app's real view model stuck in `.loading` — redacted
  # placeholder rows against the twin's recorded statuses — at 461250; then
  # 1761, once `d4cf821a` made a model held as `@State` invalidate its view
  # (`TimelineView.viewModel` is exactly that spelling), which is the
  # Client-actor fetch class this loop's capability queue put first, running
  # end to end for the first time.
  #
  # It enters at 1761 and not at the `.loading` number because 461250 was
  # measured BEFORE `9b3afeb1`, when both readiness loops expired on a fixed
  # 30s total budget: this screen's capture legitimately stalls ~181s inside
  # interpreted `HTMLString.init(from:)`, so the frame was read mid-`.loading`.
  # Bounding readiness by lack of progress instead lets it settle. Scoring the
  # older number would enshrine ~459k AE of debt that no longer exists and then
  # read its removal as progress.
  #
  # Was 1761 — ONE 140x33 box at the navigation title. The twin drew TWO lines
  # there and the interpreter drew only the first, so 1296 AE was the missing
  # `Text(client.server)` and the other 465 was the surviving line sitting
  # ~1-2px low, because a one-child VStack centers where a two-child one does
  # not: one defect plus its displacement, not two bugs.
  #
  # `TimelineToolbarTitleView` is a `ToolbarContent` conformer, NOT a View. A
  # View's `@Environment` properties are filled by the host that renders it
  # (`InterpretedView`); a non-View result-builder conformer has no such host,
  # so `@Environment(MastodonClient.self)` stayed unset and `client.server`
  # read off `()`. The conformer now sees the environment its enclosing body
  # saw. The competing hypothesis — a ViewBuilder switch case yielding MULTIPLE
  # views rendering only the first — was REFUTED by the repro rather than
  # argued away: its headline expectation passes with the fix stashed.
  trending-timeline 0
  # NEW SCREEN, entering at its first measured value — a measurement that did
  # not exist before, not a regression of one that did. The seven screens above
  # are unchanged (2 AE, all of it tags-list).
  #
  # Why it is worth scoring: every row this board has ever compared is a
  # status, an account or a tag. `StatusRowCardView` — the app's link preview,
  # with its own reserved image frame, provider line, title, author byline and
  # people-talking chip — had no pixels on the board at all, on either side.
  # `RouterDestination.trendingLinks` is the route, and `Trends.links` is
  # public and unauthenticated, so the screen is drivable end to end from a
  # recording (10 cards).
  #
  # IT ENTERS AT 0, and that is stated plainly rather than dressed up: this
  # screen decomposes nothing and discharges no debt. It is regression
  # coverage for a row type that had none, not a repair. What it does buy is
  # an answer to a question the board could not previously ask — whether the
  # card row's reserved image frame, its title/description line breaking and
  # its provider byline match the compiled app — and the answer is that they
  # already did. A screen admitted at 0 is only worth its capture time because
  # it can go RED later; it is not evidence of progress this iteration.
  #
  # It also costs no requests: ten cards overflow the 900x700 canvas, so the
  # view's own `NextPageView` footer never appears and never fetches. That is
  # what keeps the pulse animation on that footer out of the capture, and it
  # is why this screen is reproducible rather than merely lucky — verified
  # twin-vs-twin and interp-vs-interp at AE 0 before being scored.
  trending-links 0
  # NEW SCREEN, entering at its first measured value — a measurement that did
  # not exist before, not a regression of one that did. The eight screens
  # above are unchanged (2 AE, all of it tags-list).
  #
  # It is the first scored screen declared in the app TARGET rather than in a
  # package, and admitting it is the point of the iteration: the twin
  # depended only on `Packages/*`, so all 36 of the app's own files — 30 of
  # them declaring View types — were uncompilable by it and therefore
  # unscorable FOREVER, no matter how many package screens were admitted.
  # Eight screens at ~0 AE read as a converged app while an entire region of
  # the codebase had never been compared at all: `scored-subset-reads-as-
  # converged` one level up, a subset of the CODEBASE rather than of screens.
  #
  # It entered at 143467 as the honest first measurement of that region. Both
  # sides are proven reproducible at AE 0 before scoring (twin-vs-twin and
  # interp-vs-interp), so every number here is interpreter debt, never capture
  # noise. That 143467 was characterized as two independent classes, and the
  # dominant one is now DISCHARGED:
  #
  # (1) 143082 AE, FIXED. Section structure did not survive an interpreted view
  #     boundary. The `Form` gateway REBUILT the `SectionSpec`s it recognised
  #     and wrapped everything else in one implicit anonymous `Section` — but
  #     it inspected only its OWN direct builder output, so a section arriving
  #     by any other route landed inside that wrapper and NESTED. The app
  #     writes `Form { InstanceInfoSection(instance:) }` and that view's body
  #     vends the Sections one level down, so their headers rendered as
  #     ordinary rows inside a single box instead of as headers above two, and
  #     everything below shifted — one structural defect plus its displacement,
  #     which is what made the number large.
  #
  #     The premise the rebuild rested on was measured and REFUTED rather than
  #     patched around: natively, a grouped `Form` boxes an `AnyView`-erased
  #     Section, one vended through a custom view's body, one inside an indexed
  #     `ForEach` and one carrying a row modifier all identically to a section
  #     written directly in its builder. `AnyView` erasure never hid section
  #     structure from a `Form`. So the fix is subtractive — `Form` now emits
  #     straight through `builderContent` exactly like `List`, and `anyView` is
  #     the single place a `SectionSpec` becomes a real `Section`. A per-
  #     container special case was DELETED, not another one added.
  #     Pinned by `Tests/SwiftUIBridgeTests/FormSectionBoundaryMicroTwinTests
  #     .swift`, six macOS micro-twins: three routes to the defect (across a
  #     view boundary, through an erased modifier receiver, both at once) each
  #     RED at ~30602 AE with the fix stashed, plus two counter-direction pins
  #     that keep loose rows grouped now that nothing wraps them implicitly.
  #
  # (2) Was 385 — a single 41x15 cluster at x 343...383 y 660...674, where the
  #     contact row's follower count read "874,788" against native's "875K".
  #     An interpolation segment carrying a `format:` argument lost its style:
  #     `LiteralEvaluator` recognised exactly one labeled interpolation,
  #     `specifier:`, so `.number.notation(.compactName)` was evaluated and
  #     discarded and the value fell back to its `_FormatSpecifiable` reading.
  #     The style is an SDK generic the interpreter cannot build, so it now
  #     rides UNRESOLVED to the host and renders at the one seam every
  #     generated localization-key position already flows through
  #     (`CallArguments.readingLocalizationKeys`) — fixing `Text` alone would
  #     have been a per-API special case. Which style a leading-dot chain
  #     denotes is not tabulated: candidates are read out of the generated
  #     `format:` parameter types and `FormatInput` selects among them, the
  #     same constraint the SDK's own `appendInterpolation` declares.
  #     Pinned by `Tests/SwiftUIBridgeTests/LocalizedInterpolationTests.swift`,
  #     five interpreted-vs-native observables driven RED with Sources/ stashed
  #     (954, 769, 937, 1421, 1558 AE) plus four native-vs-native controls, so
  #     none can pass by drawing nothing.
  #
  # One harness property to keep in mind when reading the capture: the app
  # target's own `.xcstrings` is not in either side's bundle, so app-declared
  # LocalizedStringKeys render as raw keys ("instance.info.name") on BOTH
  # sides. That is a substitution shared by the two sides, exactly like the
  # deterministic placeholder PNG standing in for remote images — it does not
  # affect the diff, but it does mean this screen measures the app's Form
  # layout and typography rather than its localized copy.
  instance-info 0
  # ENTERING THE BOARD at its MEASURED value, never at a placeholder. The app's
  # own `DisplaySettingsView`, and the first scored screen built from the
  # ENVIRONMENT rather than from recorded bytes — it reads no fixture at all.
  #
  # What it actually puts pixels on, stated from the capture rather than from
  # the file: the viewport holds the `ZStack`'s example-post card over the top
  # of a grouped `Form`, then the theme section — a `Toggle`, a `NavigationLink`
  # row with a trailing value, and four `ColorPicker`s in their disabled and
  # dimmed state — its conditional FOOTER, and the next section's header. The
  # `Slider`s and nine `Picker`s below the fold are built but not drawn, so this
  # screen scores section chrome, control rendering and a gradient-masked
  # overlay; it does not yet score a picker's selected case or a slider's knob.
  #
  # It is the screen that found both structural classes landed alongside it, and
  # both were invisible everywhere else on the board: a `Section` footer that
  # was never read (its section is the only one on the board written with one),
  # and a sectioned collection whose content opened on a loose row. 82806 -> 439.
  #
  # Was 439 — one 51x17 box at x 808...858 y 200...216, 100% channel-neutral,
  # entirely the relative timestamp in the example post's corner: the twin drew
  # "2m" and the interpreter drew nothing after the separator dot, with the
  # card, the Form, the sections and every control around it byte-identical. A
  # `ServerDate()` relative-format class, not a layout one, and the localized
  # residue read correctly — the fix was exactly where the box said it was.
  #
  # `ServerDate.relativeFormatted` is
  # `Duration.seconds(-date.timeIntervalSinceNow).formatted(.units(...))`, and
  # the receiver could not be BUILT: the interface sweep collected a type's
  # static STORAGE but not its static FUNCS, so `Duration.zero` existed and
  # `Duration.seconds(100)` did not. The value stayed an unresolved leading-dot
  # marker and `.formatted(...)` absorbed into a chain that renders as nothing.
  #
  # Three layers, each with its own repro: the generator collects the
  # call-shaped statics (bounded by the format family's own declared
  # `FormatInput`, not a name list); the bridge builds a real `Duration` where
  # it served a marker, with both clock readers taking the named spelling
  # counter-directionally; and member access consults the argument-selected
  # host bridge before absorbing, since `formatted` is generic over its style
  # and no per-receiver table declares it. Decomposed away from this
  # whole-screen AE by `namedDurationTimestampDrawsItsFormattedText`, which
  # measures the timestamp alone at AE 112 -> 0.
  #
  # Admitting it also forced the board's third determinism input, after the
  # frozen clock and the frozen network: `Theme` and `UserPreferences` are
  # `@AppStorage`, and this screen WRITES them back from six `.task(id:)`
  # blocks. Before both processes pinned the persistent domain, capture 1
  # differed from capture 2 by 232148 AE and captures 2, 3 and 4 then agreed —
  # a screen that was a pure function of run history and that this script's
  # own reproducibility gate would have certified, since that gate compares
  # each side only against itself.
  display-settings 0
  # Measured on the tree that admits it, never guessed. The screen first
  # captured at 104326 against this same twin; the two commits below it in
  # this lane (a scalar's type identity, then an array annotation's element
  # deciding the overload) took it to 4073 before it was ever scored, so the
  # floor it enters at is the post-fix number.
  #
  # It entered at 4073, which `Scripts/pixel-diff-map.swift` split into TWO
  # divergences at the row-1/row-2 boundary. One is now DISCHARGED:
  #
  # Was 1733 — the `status.row.is-thread` label, drawn 8pt left of the twin on
  # every scanline. `StatusRowView.swift:74` pads that group by
  # `AvatarView.FrameConfig.status.width + .statusColumnsSpacing`, and the
  # leading-dot operand absorbed, so the interpreter padded by the bare 48.
  # The avatar (48 wide) and `HStack(spacing: .statusColumnsSpacing)` (8) were
  # both already correct on the same rows, which is what said the defect was
  # the OPERAND POSITION rather than the static, the constant or the
  # `#if targetEnvironment(macCatalyst)` branch. Pinned by
  # `Tests/SwiftInterpreterTests/OperandContextualImplicitMemberTests.swift`.
  #
  # What is LEFT is the inter-row separator, which the interpreter draws only
  # 120px wide where the twin runs the full 900 (EDGE-GEOMETRY, 2340 AE). The
  # two sides agree pixel for pixel through x=119 — same y, same 253/233/253
  # antialiasing — so this is a width, not a colour, an inset or a missing
  # decoration. It is NOT a general separator gap: the separator at y=199 on
  # this same screen is 900/900 on BOTH sides, and every separator on the
  # `timeline` screen is 880/900 on both. Only the boundary above the row
  # carrying `.alignmentGuide(.listRowSeparatorLeading) { _ in -100 }` and the
  # padded thread-label group diverges.
  hashtag-timeline 2340
)
# A screen captured but unscored is indistinguishable from a screen that
# converged, so the two lists must name exactly the same screens.
for screen in "${R2_SCREENS[@]}"; do
  if [[ -z "${R2_FLOORS[$screen]+set}" ]]; then
    echo "R2 board: '$screen' is captured but carries no floor" >&2
    exit 2
  fi
done
for screen in "${(@k)R2_FLOORS}"; do
  if (( ! ${R2_SCREENS[(Ie)$screen]} )); then
    echo "R2 board: '$screen' carries a floor but is never captured" >&2
    exit 2
  fi
done
typeset -A R2_AE_LINES
board_red=0
board_below=0

for screen in "${R2_SCREENS[@]}"; do
  ae_line="$(xcrun swift Scripts/pixel-ae.swift \
    "$TWIN_DIR/$screen.png" "$INTERP_DIR/$screen.png")"
  ae_status=$?
  if (( ae_status == 2 )); then
    echo "$screen R2 board: pixel comparison failed —" \
      "$ae_line (size/format mismatch or unreadable capture)" >&2
    exit 2
  fi
  ae_count="$(print -r -- "$ae_line" | sed -E 's/^AE ([0-9]+) of .*/\1/')"
  if [[ ! "$ae_count" == <-> ]]; then
    echo "$screen R2 board: could not parse AE count from '$ae_line'" >&2
    exit 2
  fi
  R2_AE_LINES[$screen]="$ae_line"
  floor="${R2_FLOORS[$screen]}"
  print -r -- "$screen"$'\t'"$ae_line"$'\t'"floor=$floor"
  if (( ae_count > floor )); then
    echo "═══ $screen R2 board: OVER FLOOR — AE $ae_count > $floor (regression) ═══"
    board_red=1
  elif (( ae_count < floor )); then
    echo "═══ $screen R2 board: BELOW FLOOR — ratchet $floor to $ae_count in this commit ═══"
    board_below=1
  else
    echo "═══ $screen R2 board: AT FLOOR — AE $ae_count == $floor ═══"
  fi
done

# gate.sh deliberately consumes the last unlabelled AE line as the official
# timeline R2 metric.
print -r -- "${R2_AE_LINES[timeline]}"
if (( board_red != 0 )); then
  exit 1
fi
if (( board_below != 0 )); then
  echo "═══ R2 board: GREEN below at least one floor; commit the tighter floor ═══"
  exit 0
fi
echo "═══ R2 board: GREEN at all floors ═══"
exit 0
