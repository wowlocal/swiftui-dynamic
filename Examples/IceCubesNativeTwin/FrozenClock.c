// Harness-only wall-clock injection shared by the native and interpreted
// IceCubes capture processes. Foundation.Date's zero-argument initializer is
// one semantic source of wall time across every package; interposing it keeps
// relative timestamps deterministic without modifying the app's sources.
// ContinuousClock/DispatchTime are deliberately untouched so sleeps, run-loop
// deadlines, and async scheduling continue to advance normally.

#include <errno.h>
#include <stdlib.h>
#include <time.h>

// `Date` stores one Double expressed as seconds since Foundation's 2001
// reference date. Because Foundation is a resilient module, Swift returns it
// through arm64's indirect-result register (x8), rather than as a C double.
extern double foundation_date_init(void)
    __asm__("_$s10Foundation4DateVACycfC");

static double current_reference_time(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_REALTIME, &value) != 0) {
    return 0.0;
  }
  const double unix_time =
      (double)value.tv_sec + ((double)value.tv_nsec / 1000000000.0);
  return unix_time - 978307200.0;
}

double harness_reference_time(void) {
  const char *raw = getenv("ICECUBES_FROZEN_NOW");
  if (raw == NULL || raw[0] == '\0') {
    return current_reference_time();
  }

  errno = 0;
  char *end = NULL;
  const double unix_time = strtod(raw, &end);
  if (errno != 0 || end == raw || *end != '\0') {
    return current_reference_time();
  }
  return unix_time - 978307200.0;
}

#if !defined(__arm64__)
#error "The IceCubes twin and root package currently build arm64 captures only"
#endif

// Preserve the Swift calling convention of Date.init(): write the single
// stored Double through x8. The helper itself stays ordinary C so parsing the
// injected epoch remains straightforward and independently testable.
extern void harness_date_init_swift(void);
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl _harness_date_init_swift\n"
    "_harness_date_init_swift:\n"
    "stp x29, x30, [sp, #-32]!\n"
    "str x19, [sp, #16]\n"
    "mov x29, sp\n"
    "mov x19, x8\n"
    "bl _harness_reference_time\n"
    "str d0, [x19]\n"
    "ldr x19, [sp, #16]\n"
    "ldp x29, x30, [sp], #32\n"
    "ret\n");

// The SECOND semantic source of wall time, and the one `Date.init()` alone
// could not reach. `Date.timeIntervalSinceNow` computes its "now" INSIDE
// Foundation, so the call never crosses an image boundary and dyld
// interposition — which only rewrites cross-image calls — leaves it reading
// the real clock. A date built from the frozen instant then measured against
// the real one yields the elapsed time SINCE the freeze, which grows without
// bound as the harness ages.
//
// IceCubes renders exactly that: `Status.placeholder` (the example post on the
// settings screens) is `ServerDate()`, i.e. `Date() - 100`, and
// `ServerDate.relativeFormatted` takes its `else` branch —
// `Duration.seconds(-date.timeIntervalSinceNow)` — because the placeholder is
// not older than a day. Frozen `Date()` minus real now drew "525h" and ticked
// once an HOUR, so the twin and the interpreted capture (taken minutes apart)
// disagreed whenever they straddled an hour boundary. Every other screen
// escaped it only by luck of branch: recorded statuses ARE older than a day
// and take the sibling branch, which spells `Date()` explicitly and so was
// already frozen.
//
// `Date` is one stored `Double`, and Foundation is resilient, so it is
// address-only across the module boundary and `self` arrives INDIRECTLY — the
// mirror of the x8 indirect RESULT the initializer above documents. What it
// does NOT arrive in is x0: Swift passes `self` in x20, the reserved
// `swiftself` register, and reading x0 instead reads whatever the caller
// happened to leave there.
//
// That is not a guess. Disassembling the twin's own call sites shows every one
// materializing `self` into x20 and nothing into x0 —
// `ServerDate.relativeFormatted` loads `ldur x20, [x29, #-0x40]` immediately
// before `bl ...timeIntervalSinceNowSdvg`, and the accessor thunk at the third
// site simply forwards the x20 it was entered with. Reading x0 instead
// dereferences whatever address the caller last left there, and the
// CONSEQUENCE IS PER-PROCESS — which is the reason this is a determinism bug
// and not merely a wrong number. Measured three ways on the same probe
// (`Date() - 100`, the shape `ServerDate()` builds): with no interposer at all
// the real clock leaks and it renders "527h", ticking once an hour; reading x0
// it renders "223,860h" in the twin, where the stale pointer happened to
// address zeroed memory so `0 - frozen_now` reported the entire frozen epoch
// as an interval, and SEGFAULTS in a standalone macOS probe, where it did not;
// reading x20 it renders "2m" in both.
extern double foundation_date_time_interval_since_now(const void *self)
    __asm__("_$s10Foundation4DateV20timeIntervalSinceNowSdvg");

// The arithmetic stays ordinary C — a date's interval to "now" is its own
// stored instant minus the frozen one — so only the single `mov` below carries
// any calling-convention knowledge.
double harness_date_interval_to_frozen_now(const double *self) {
  if (self == NULL) {
    return 0.0;
  }
  return *self - harness_reference_time();
}

// Translate Swift's `self` register into the C argument register and tail-call.
// `Date` is address-only, so x20 holds the ADDRESS of the stored Double, which
// is exactly the pointer the helper above wants; the `double` result is already
// in d0 for both conventions, so nothing else needs adjusting.
extern void harness_date_time_interval_since_now(void);
__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl _harness_date_time_interval_since_now\n"
    "_harness_date_time_interval_since_now:\n"
    "mov x0, x20\n"
    "b _harness_date_interval_to_frozen_now\n");

struct interpose_entry {
  const void *replacement;
  const void *replacee;
};

__attribute__((used, section("__DATA,__interpose")))
static const struct interpose_entry interposers[] = {
    {(const void *)harness_date_init_swift, (const void *)foundation_date_init},
    {(const void *)harness_date_time_interval_since_now,
     (const void *)foundation_date_time_interval_since_now},
};
