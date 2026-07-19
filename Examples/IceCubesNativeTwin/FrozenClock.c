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

struct interpose_entry {
  const void *replacement;
  const void *replacee;
};

__attribute__((used, section("__DATA,__interpose")))
static const struct interpose_entry interposers[] = {
    {(const void *)harness_date_init_swift, (const void *)foundation_date_init},
};
