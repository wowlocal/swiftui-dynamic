#!/bin/zsh
# verify-subject-revisions.sh — the subject under test is PINNED, as an EXIT CODE.
#
# The close gate publishes numbers about source trees it never named. `External/` is gitignored
# (.gitignore:5); External/oss/IceCubesApp has been at 9c05a72 ("More compile fix", 2026-06-09)
# since before the R2 board existed, and on 2026-08-08 a grep for that sha across every .md, .sh,
# .rb and .json in the repository returned NOTHING. So: `Scripts/icecubes-r2.sh` carries ten
# per-screen AE floors, `IceCubesCheck` carries nine rungs, `ProjectCheck` carries a 680-unit
# census — and every one of those is a measurement of a tree whose revision was recorded nowhere.
# A `git pull` inside any subject checkout would turn all of them into claims about a different
# program, in silence, and the first suspicion would fall on the interpreter.
#
# This is the same execution gap this repository has now recorded three times: a rule that can be
# checked mechanically must be checked by a script that exits non-zero, because prose rules
# demonstrably do not fire (AUDIT-2026-07-24-execution-gap.md, AUDIT-2026-07-28-generation-
# leverage.md, and the §5 leverage ratchet crossed inside the 08-04..08-07 window with nothing
# noticing). "Do not move External/" is prose. This is the exit code.
#
#   ./Scripts/verify-subject-revisions.sh             enforce; exit 1 on drift
#   ./Scripts/verify-subject-revisions.sh --print     report only, always exit 0
#   ./Scripts/verify-subject-revisions.sh --self-test verify the comparison logic itself, exit 0
#
# ABSENCE IS `n/a`, NEVER DRIFT — the failure mode most likely to hurt, so it is stated first. The
# gate builds a clean detached worktree and symlinks `External` in; a subject that is not on disk
# is an environment fact, not a finding. The gate's board contract sanctions a SECOND census,
# `586/586`, which IS lane-concurrency's environment with External/oss not checked out at all. A
# validator that exits 1 on a missing gitignored input pins nothing — it blocks every gate on the
# machines that need it least. Absent subjects are counted, reported, and scored ZERO.
#   grep -n 'projects pass' Scripts/gate.sh   →  the `586/586` and `678/680` board-contract cases
# That contract is cited here as a GREP and never as a line number. It is deep inside gate.sh's
# board-contract loop, hundreds of lines of stage code move above it whenever a stage is added
# (two were added while this script was being written, and the `:1210` this comment carried until
# then had already become an unrelated evaluation stage). A citation that rots is how a claim
# outlives its evidence — the exact failure this file exists to end, one level up.
#
# Measures the WORKING TREE from the checkout root, so it is correct in the main checkout, in a
# lane worktree, and in the clean-detached checkout the closing gate builds. Per subject it reads
# HEAD and a `git diff --name-only HEAD` (index + stat, no object walk): no build, no capture, no
# network, no write — 2.3s over all 95 subjects, safe to run beside a live gate.
set -u

MANIFEST=${SUBJECT_REVISIONS_MANIFEST:-Scripts/subject-revisions.tsv}

# ── Thresholds ────────────────────────────────────────────────────────────────────────────────
# Each threshold names the exact command that produces it, measured 2026-08-08 at 0532322f.

# The manifest must not be gutted. This is NOT a ban on retiring a corpus project: the exact
# census (`678/680`; `grep -n 'projects pass' Scripts/gate.sh`) already makes removing one a
# deliberate, gate-visible act. It catches the manifest losing rows WITHOUT anyone deciding to —
# a truncated write, a bad regeneration, a merge that kept one side. 95 today; the floor sits five
# rows below, so the ordinary case (one subject retired with its census update) does not move it.
#   grep -cvE '^[[:space:]]*(#|$)' Scripts/subject-revisions.tsv   →  95
FLOOR_MANIFEST_ROWS=90

# A pin shorter than git's own default abbreviation is not a pin. Seven hex characters is what
# `git log --oneline` prints and what the 2026-08-08 audit quoted for IceCubesApp (`9c05a72`), so
# a hand-shortened pin is accepted — but four characters would match ~1 tree in 65536 by accident,
# which is a pin that cannot fail. The manifest carries full 40-character shas; this only bounds
# what a human may shorten one to.
MIN_PIN_LENGTH=7

# ── Comparison logic ──────────────────────────────────────────────────────────────────────────
# `classify` is the entire judgement of this script and takes NO filesystem input, so --self-test
# drives every verdict from synthetic strings. Everything below it only decides what to feed it.

integer violations=0
integer n_ok=0 n_drift=0 n_absent=0 n_unpinnable=0 n_badpin=0
integer n_dirty=0 n_unpinned=0
typeset -a drift_lines drifted_names absent_names dirty_names unpinned_names
drift_lines=() drifted_names=() absent_names=() dirty_names=() unpinned_names=()
typeset verdict=""

# classify <subject> <expected-sha> <found-sha-or-sentinel>
# Sentinels for <found>: ABSENT (not on disk), NOT-A-GIT-CHECKOUT, NO-HEAD.
# Sets $verdict to one of: ok | drift | absent | unpinnable | badpin.
# Only drift, unpinnable and badpin score a violation.
classify() {
    local subject=$1 expected=$2 found=$3
    local e=${(L)expected} f=${(L)found}

    # A malformed pin is a manifest defect whether or not the subject is on disk, so it is judged
    # before everything else: a two-character pin would match almost every tree, and a check that
    # can only pass is the prose it replaced.
    if [[ ! "$expected" =~ '^[0-9a-fA-F]+$' || ${#expected} -lt $MIN_PIN_LENGTH ]]; then
        verdict=badpin
        (( n_badpin++ )); (( violations++ ))
        drift_lines+=("  BAD PIN     $subject — '$expected' is not at least $MIN_PIN_LENGTH hex characters")
        return 0
    fi

    if [[ "$found" == "ABSENT" ]]; then
        verdict=absent
        (( n_absent++ ))
        absent_names+=("$subject")
        return 0
    fi

    # Present but unpinnable is NOT the same as absent and must not quietly read as one: an
    # exported tarball, or a `.git` that was removed, leaves the boards scoring a tree that no
    # revision can name — exactly the state this script exists to end.
    if [[ "$found" == "NOT-A-GIT-CHECKOUT" || "$found" == "NO-HEAD" ]]; then
        verdict=unpinnable
        (( n_unpinnable++ )); (( violations++ ))
        drift_lines+=("  UNPINNABLE  $subject — on disk but $found; pinned at $expected")
        return 0
    fi

    # Prefix comparison, so a hand-written `9c05a72` pins the same tree as the full sha. A FOUND
    # value shorter than the pin can never satisfy it (the first 40 characters of a 7-character
    # string are 7 characters, which is not the 40-character pin). That asymmetry is deliberate
    # and the self-test covers it, because a degraded probe must never read as agreement.
    if [[ "${f:0:${#e}}" == "$e" ]]; then
        verdict=ok
        (( n_ok++ ))
        return 0
    fi

    verdict=drift
    (( n_drift++ )); (( violations++ ))
    drifted_names+=("$subject")
    drift_lines+=("  DRIFT       $subject — pinned at $expected, found $found")
    return 0
}

read_manifest_rows() {
    # One `subject<TAB>sha<TAB>consumers` line per DATA row. Comments and blank lines are dropped
    # HERE so that the enforcing path, the row count, and the self-test all agree on what a row
    # is — and so the count matches the command committed beside FLOOR_MANIFEST_ROWS exactly.
    grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true
}

count_lines() {
    # Line count of a VALUE that is already in hand, deliberately NOT `something | wc -l`. A
    # pipeline reports only its LAST stage's status, and `wc -l` answers `0` exactly as cheerfully
    # when an upstream stage died as when there was genuinely nothing to count — so a broken
    # measurement is indistinguishable from a clean one and the check it feeds silently passes.
    # (`set -o pipefail` is not enabled globally: the reference validator this one is modelled on,
    # Scripts/validate-anti-drift.sh, runs under `set -u` alone — `grep -n 'set -' ...` — and a
    # global pipefail would also make the `… | head -1` below fail whenever `head` closes the pipe
    # early. Where a pipeline is unavoidable, its status is taken explicitly, with pipefail scoped
    # to that one subshell.)
    # An empty value is ZERO lines, not one.
    [[ -n "$1" ]] || { print -r -- 0; return 0 }
    local -a lines
    lines=("${(@f)1}")
    print -r -- ${#lines}
}

join_capped() {
    # Comma-joins its arguments, capped. The marker is a RECEIPT LINE, and every list in it can go
    # degenerate at once (a manifest that selected nothing while 94 checkouts sit on disk makes all
    # 94 `unpinned`), which would put kilobytes on one line of every gate log. The COUNT beside it
    # is exact; this is the sample.
    if (( $# > 12 )); then
        print -r -- "${(j:,:)${@[1,12]}},+$(( $# - 12 )) more"
    else
        print -r -- "${(j:,:)@}"
    fi
}

scored_changes() {
    # Its arguments minus the paths a dependency resolver owns, one per line. Pure string logic
    # with no filesystem input, so --self-test drives it directly; see probe_dirty for WHY.
    local -a kept
    kept=(${@:#(*/|)Package.resolved})
    (( ${#kept} > 0 )) && print -rl -- $kept
    return 0
}

# ── Self-test ─────────────────────────────────────────────────────────────────────────────────

expect_verdict() {
    local want=$1 want_violations=$2 subject=$3 expected=$4 found=$5
    classify "$subject" "$expected" "$found"
    if [[ "$verdict" != "$want" ]]; then
        print -u2 "self-test: $subject ($expected vs $found) — expected verdict $want, got $verdict"
        exit 1
    fi
    if (( violations != want_violations )); then
        print -u2 "self-test: $subject — expected running violation count $want_violations," \
            "got $violations"
        exit 1
    fi
}

if [[ "${1:-}" == "--self-test" ]]; then
    typeset full=9c05a720597b3ff13de2e241bf58d3fba0863c09

    expect_verdict ok         0 identical       "$full" "$full"
    expect_verdict drift      1 moved           "$full" 0532322f0000000000000000000000000000abcd
    # THE failure mode this script must not have: a gitignored subject that is simply not on this
    # machine is an environment fact. It reports n/a and the violation count does NOT move.
    expect_verdict absent     1 not-checked-out "$full" ABSENT
    expect_verdict unpinnable 2 exported        "$full" NOT-A-GIT-CHECKOUT
    expect_verdict unpinnable 3 empty-clone     "$full" NO-HEAD
    # A hand-shortened pin still pins — and still fails when it is wrong by one character.
    expect_verdict ok         3 short-pin       9c05a72 "$full"
    expect_verdict drift      4 short-pin-wrong 9c05a73 "$full"
    expect_verdict ok         4 case-folded     9C05A720597B3FF13DE2E241BF58D3FBA0863C09 "$full"
    # The asymmetry: a truncated FOUND cannot satisfy a full pin.
    expect_verdict drift      5 truncated-found "$full" 9c05a72
    # A pin nobody can fail is worse than no pin. Both spellings are manifest defects.
    expect_verdict badpin     6 stub-pin        9c05    "$full"
    expect_verdict badpin     7 not-hex         HEAD    "$full"

    # The row reader must agree with the committed row-count command about comments and blanks,
    # and must split on TAB rather than on whitespace — a subject path may contain spaces.
    typeset fixture=${TMPDIR:-/tmp}/subject-revisions-selftest.$$.tsv
    {
        print -r -- "# a comment"
        print -r -- "   # an indented comment"
        print -r -- ""
        print -r -- "   "
        printf 'External/oss/One Two\t%s\tevaluation\n' "$full"
        printf 'External/deps/Three\t%s\tlive\n' "$full"
    } > "$fixture"
    typeset rows=$(read_manifest_rows "$fixture" | wc -l | tr -d ' ')
    typeset first_subject=$(read_manifest_rows "$fixture" | head -1 | cut -f1)
    rm -f "$fixture"
    if [[ "$rows" != 2 ]]; then
        print -u2 "self-test: row reader counted $rows data rows, expected 2"
        exit 1
    fi
    if [[ "$first_subject" != "External/oss/One Two" ]]; then
        print -u2 "self-test: row reader split the wrong field, got '$first_subject'"
        exit 1
    fi

    # count_lines must answer 0 for nothing — the whole reason it exists is that `wc -l` in a
    # pipeline answers 0 for a DEAD upstream stage, so the counter that replaces it has to be
    # exact at the boundary it was introduced to protect.
    expect_count() {
        local want=$1 label=$2 value=$3 got
        got=$(count_lines "$value")
        if [[ "$got" != "$want" ]]; then
            print -r -u2 -- "self-test: count_lines($label) = $got, expected $want"
            exit 1
        fi
    }
    expect_count 0 empty       ""
    expect_count 1 one-line    "one"
    expect_count 2 two-lines   $'one\ntwo'
    expect_count 3 three-lines $'one\ntwo\nthree'
    # An interior blank line is still a line — `${(f)…}` and `wc -l` agree here, and the callers
    # (git path lists, an `ls -1` listing, `uniq -d`) never produce one anyway.
    expect_count 3 interior-blank $'one\n\nthree'

    # The resolver-owned exclusion, at both spellings a real subject produces. Getting this wrong
    # in the tolerant direction hides a local patch; getting it wrong in the strict direction reds
    # the gate on an ordinary SwiftPM resolve, which is how the stage gets disabled.
    typeset kept
    kept=$(scored_changes Package.resolved Packages/Account/Package.resolved Sources/Foo.swift)
    if [[ "$kept" != "Sources/Foo.swift" ]]; then
        print -u2 "self-test: scored_changes kept '${kept//$'\n'/, }', expected Sources/Foo.swift"
        exit 1
    fi
    if [[ -n "$(scored_changes Package.resolved)" ]]; then
        print -u2 "self-test: scored_changes counted a lone Package.resolved as a local edit"
        exit 1
    fi
    # A file that merely CONTAINS the name is not resolver-owned.
    if [[ "$(scored_changes Package.resolved.bak)" != "Package.resolved.bak" ]]; then
        print -u2 "self-test: scored_changes over-matched Package.resolved.bak"
        exit 1
    fi
    if [[ "$(count_lines "$(scored_changes Package.resolved)")" != 0 ]]; then
        print -u2 "self-test: an all-resolver change set did not count as zero dirty files"
        exit 1
    fi

    print "@@subject-revisions-self-test passed (11 verdicts, 7 scored as violations, 2 data rows," \
        "5 line counts, 4 resolver-exclusion cases)"
    exit 0
fi

# ── Measurement ───────────────────────────────────────────────────────────────────────────────

probe_subject() {
    # Answers what revision the subject is ACTUALLY at, or which sentinel explains why there is no
    # answer. It never guesses.
    local dir=$1
    [[ -d "$dir" ]] || { print -r -- ABSENT; return 0 }

    # `git -C` ASCENDS. If the subject is a plain directory rather than a checkout, git answers
    # with THIS repository's HEAD — every subject would then "match" whatever sha the interpreter
    # happens to sit on and the pin would be pure decoration. Compare the toplevel git found
    # against the subject itself, PHYSICALLY, because `External` is a symlink in every lane
    # worktree and the two spellings of one directory must compare equal.
    local top physical_dir physical_top sha
    top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) \
        || { print -r -- NOT-A-GIT-CHECKOUT; return 0 }
    physical_dir=$(cd "$dir" 2>/dev/null && pwd -P) || { print -r -- ABSENT; return 0 }
    physical_top=$(cd "$top" 2>/dev/null && pwd -P) || { print -r -- NOT-A-GIT-CHECKOUT; return 0 }
    [[ "$physical_dir" == "$physical_top" ]] || { print -r -- NOT-A-GIT-CHECKOUT; return 0 }

    sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || { print -r -- NO-HEAD; return 0 }
    [[ -n "$sha" ]] || { print -r -- NO-HEAD; return 0 }
    print -r -- "$sha"
}

probe_dirty() {
    # How many TRACKED files the subject has modified relative to its own HEAD, after dropping the
    # paths a dependency resolve owns. The pin above is a HEAD comparison, so without this a local
    # patch inside a subject — one that makes a floor pass — leaves HEAD untouched and this whole
    # validator green. That is the shape of the measurement-calibrated-constant class AGENTS.md §4
    # records: the number moves out of the place anything counts it.
    #
    # It is REPORTED and scores ZERO, and the reasons are load-bearing enough that the next person
    # should not "fix" that:
    #
    #   1. RESOLVER-OWNED FILES. Examples/IceCubesNativeTwin/Package.swift builds against
    #      `../../External/oss/IceCubesApp/Packages`, and SwiftPM rewrites `Package.resolved`
    #      IN PLACE inside those package directories when it resolves. A dirty ratchet that scored
    #      those would red the close gate on an ordinary build of the twin — an environment fact
    #      wearing a finding's clothes, and the fastest route to this whole stage being disabled.
    #      They are excluded here rather than tolerated by a threshold, so the count stays exact.
    #   2. UNTRACKED FILES ARE NOT MEASURED AT ALL. They are build output and vendored checkouts;
    #      External/oss/swift-composable-architecture carries an untracked `VendoredDependencies/`
    #      on a clean machine today. Which revision is being measured is a question about tracked
    #      content.
    #   3. Enforcing it HERE would be enforcing it in the wrong place. The remedy for a local patch
    #      is that it becomes visible in every receipt; making it fatal mostly means the receipt
    #      stops being produced on precisely the machines where the subjects are checked out.
    #
    # Answers 0 for anything it cannot measure: this is a report, so a failed probe must not
    # manufacture a finding.
    local dir=$1 changed
    changed=$(git -C "$dir" diff --name-only HEAD -- 2>/dev/null) || { print -r -- 0; return 0 }
    count_lines "$(scored_changes ${(f)changed})"
}

if [[ ! -r "$MANIFEST" ]]; then
    print -u2 "subject-revisions: cannot read $MANIFEST — run this from a checkout root, not a" \
        "subdirectory (or point SUBJECT_REVISIONS_MANIFEST at it)"
    exit 2
fi

integer manifest_rows=0
typeset icecubes_expected="" icecubes_found="" icecubes_verdict="n/a"
typeset subject expected consumers found
integer subject_dirty=0
# Every subject the manifest names, and the directories those subjects live in. The reverse limb
# below derives its roots from THESE rather than hardcoding `External/oss` — a second copy of that
# constant is the §4 duplication this repository keeps finding, and deriving it means a new subject
# family gets its reverse check for free, from the manifest row that introduces it.
typeset -a manifest_subjects manifest_roots
manifest_subjects=() manifest_roots=()

while IFS=$'\t' read -r subject expected consumers; do
    [[ -n "$subject" ]] || continue
    (( manifest_rows++ ))
    manifest_subjects+=("$subject")
    manifest_roots+=("${subject:h}")
    found=$(probe_subject "$subject")
    classify "$subject" "$expected" "$found"
    if [[ "$verdict" == ok || "$verdict" == drift ]]; then
        subject_dirty=$(probe_dirty "$subject")
        if (( subject_dirty > 0 )); then
            (( n_dirty++ ))
            dirty_names+=("$subject ($subject_dirty)")
        fi
    fi
    if [[ "$subject" == "External/oss/IceCubesApp" ]]; then
        icecubes_expected=$expected
        icecubes_found=$found
        icecubes_verdict=$verdict
    fi
done < <(read_manifest_rows "$MANIFEST")

# A manifest that selected nothing is not a green pin, it is a broken measurement — the same trap
# validate-anti-drift.sh exits 2 on when its file selection matches nothing.
if (( manifest_rows == 0 )); then
    print -u2 "subject-revisions: $MANIFEST parsed to ZERO data rows — the pin is not measuring" \
        "anything; check that its columns are TAB separated"
    exit 2
fi

# Two rows for one subject means whichever loses is unenforced. The pipeline's status is taken
# EXPLICITLY (pipefail scoped to this subshell, then the count taken from the value): written as
# `integer n=$(... | wc -l)`, a dead upstream stage — an unreadable manifest, a `cut` that is not
# on PATH — yields 0, which is indistinguishable from "no duplicates" and passes in silence.
typeset duplicate_list=""
if ! duplicate_list=$(set -o pipefail; read_manifest_rows "$MANIFEST" | cut -f1 | sort | uniq -d)
then
    print -u2 "subject-revisions: the duplicate-subject scan of $MANIFEST FAILED — a stage of that" \
        "pipeline died, so its answer would be a silent 0; treating it as a broken measurement"
    exit 2
fi
integer duplicate_subjects=$(count_lines "$duplicate_list")

# REVERSE LIMB: a directory sitting under one of the manifest's own roots with NO row pinning it.
# The manifest pins the 95 subjects it names and, without this, says nothing whatsoever about a
# 96th appearing on disk — which ProjectCheck would score (it walks the DIRECTORY, not this file)
# while nothing named its revision. That is the same hole as the original one, one layer out.
#
# Reported with ceiling n/a, never scored, for a specific reason: dropping a new checkout under
# External/oss is exactly how a corpus project is proposed, and this stage runs BEFORE the census
# that would admit it. A validator that red-lit the first step of its own intended workflow gets
# routed around. Putting the count in the marker makes the coupling to the corpus census visible in
# every receipt instead of only in a comment — if `unpinned` is nonzero while the census still says
# 678/680, the two are measuring different sets and the receipt now says so.
typeset root dir
for root in ${(u)manifest_roots}; do
    [[ -d "$root" ]] || continue
    for dir in "$root"/*(N-/); do
        dir=${dir%/}
        (( ${manifest_subjects[(Ie)$dir]} )) && continue
        (( n_unpinned++ ))
        unpinned_names+=("$dir")
    done
done

# The ProjectCheck corpus root is the OTHER unpinned subject: 586 of the 680 census units come out
# of a directory inside one person's home. It carries no revision to compare (zips and folders,
# not checkouts), so it is REPORTED and never scored — its cardinality is already pinned by the
# gate's exact-match census contract.
#
# BOTH limbs below select by grepping the ProjectCheck SOURCE DIRECTORY recursively, and the
# default is read out of whatever that selection finds rather than transcribed here — a second
# copy of a constant is the §4 violation this repo keeps finding. Pinning one exact file path
# instead would mean an ordinary refactor (the root resolution moving into its own file, override
# fully intact) reds the close gate while a real deletion and a rename look identical. The rule
# being checked is "ProjectCheck still reads PROJECTCHECK_CORPUS_ROOT", not "line N of main.swift
# still says so", so the check is over the directory.
typeset -a corpus_root_files
typeset corpus_root_default="" corpus_root corpus_root_overridable=n/a
if [[ -d Sources/ProjectCheck ]]; then
    corpus_root_files=(${(f)"$(grep -rl 'PROJECTCHECK_CORPUS_ROOT' Sources/ProjectCheck 2>/dev/null)"})
    corpus_root_files=(${corpus_root_files:#})
    # Same degradation rule as the subjects: a source tree that is not here at all (this script was
    # pointed at a manifest from outside a checkout) is an environment fact and scores nothing —
    # only a ProjectCheck that EXISTS and has lost the override is a finding.
    if (( ${#corpus_root_files} > 0 )); then
        corpus_root_overridable=true
        corpus_root_default=$(grep -h -A2 'PROJECTCHECK_CORPUS_ROOT' $corpus_root_files 2>/dev/null \
            | sed -n 's/.*?? "\([^"]*\)".*/\1/p' | head -1)
    else
        corpus_root_overridable=false
    fi
fi
corpus_root=${PROJECTCHECK_CORPUS_ROOT:-${corpus_root_default:-unknown}}

# Counted from the listing itself, not through `ls | wc -l`: see count_lines. An `ls` that fails
# leaves the entry count at its `n/a` sentinel instead of reporting a confident zero.
typeset corpus_listing=""
integer corpus_entries=-1
if [[ "$corpus_root" != unknown && -d "$corpus_root" ]]; then
    if corpus_listing=$(ls -1 "$corpus_root" 2>/dev/null); then
        corpus_entries=$(count_lines "$corpus_listing")
    fi
fi

# ── Report ────────────────────────────────────────────────────────────────────────────────────

print "── subject revisions (the out-of-tree trees every board scores) ──"
printf '  %-22s %8s   floor %s   (%s)\n' "manifest rows" "$manifest_rows" \
    "$FLOOR_MANIFEST_ROWS" "$MANIFEST"
printf '  %-22s %8s\n' "matching" "$n_ok"
printf '  %-22s %8s   ceil  0\n' "DRIFTED" "$n_drift"
printf '  %-22s %8s   ceil  0   (on disk, but no revision names it)\n' "unpinnable" "$n_unpinnable"
printf '  %-22s %8s   ceil  0   (manifest defects)\n' "bad pins" "$n_badpin"
printf '  %-22s %8s             (gitignored input not on this machine)\n' "absent (n/a)" "$n_absent"
printf '  %-22s %8s   ceil  n/a   (tracked local edits; HEAD still matches)\n' \
    "dirty (n/a)" "$n_dirty"
printf '  %-22s %8s   ceil  n/a   (on disk under a manifest root, pinned by nobody)\n' \
    "unpinned (n/a)" "$n_unpinned"
printf '  %-22s %8s   ceil  0\n' "duplicate subjects" "$duplicate_subjects"
printf '  %-22s %8s   pin   %s\n' "IceCubesApp" "$icecubes_verdict" \
    "${icecubes_expected:-<not in manifest>}"
if (( corpus_entries >= 0 )); then
    printf '  %-22s %8s   entries in %s\n' "corpus root" "$corpus_entries" "$corpus_root"
else
    printf '  %-22s %8s   %s (not on this machine)\n' "corpus root" "n/a" "$corpus_root"
fi
printf '  %-22s %8s             (PROJECTCHECK_CORPUS_ROOT, must not be false)\n' \
    "corpus root override" "$corpus_root_overridable"
print_sample() {
    # <label> <name>... — a bounded sample of a reported-only list, so 94 absent subjects on a
    # lane machine do not bury the numbers above them.
    local label=$1; shift
    (( $# > 0 )) || return 0
    if (( $# > 6 )); then
        print "  $label: ${(j:, :)${@[1,6]}} … and $(( $# - 6 )) more"
    else
        print "  $label: ${(j:, :)@}"
    fi
}
print_sample absent $absent_names
print_sample "dirty (reported, not scored)" $dirty_names
print_sample "unpinned (reported, not scored)" $unpinned_names
for line in $drift_lines; do
    print -u2 -- "$line"
done

if [[ "$corpus_root_overridable" == false ]]; then
    print -u2 "SUBJECT-REVISIONS corpus-root: no file under Sources/ProjectCheck reads" \
        "PROJECTCHECK_CORPUS_ROOT — the 586-unit corpus root is an unnameable hardcoded path again"
    (( violations++ ))
fi
if (( manifest_rows < FLOOR_MANIFEST_ROWS )); then
    print -u2 "SUBJECT-REVISIONS manifest-rows: $manifest_rows is BELOW its committed floor" \
        "$FLOOR_MANIFEST_ROWS — the pin lost rows; restore them, or move the floor with a reason"
    (( violations++ ))
fi
if (( duplicate_subjects > 0 )); then
    print -u2 "SUBJECT-REVISIONS duplicates: $duplicate_subjects subject(s) are pinned twice —" \
        "one of each pair is unenforced"
    (( violations++ ))
fi

typeset drifted_sample unpinned_sample dirty_sample
drifted_sample=$(join_capped $drifted_names)
unpinned_sample=$(join_capped $unpinned_names)
dirty_sample=$(join_capped $dirty_names)

print "@@subject-revisions {\"version\":1,\"manifest\":\"$MANIFEST\",\"manifestRows\":$manifest_rows,\"manifestRowFloor\":$FLOOR_MANIFEST_ROWS,\"matching\":$n_ok,\"drifted\":$n_drift,\"unpinnable\":$n_unpinnable,\"badPins\":$n_badpin,\"absent\":$n_absent,\"dirty\":$n_dirty,\"unpinned\":$n_unpinned,\"duplicateSubjects\":$duplicate_subjects,\"driftedSubjects\":\"$drifted_sample\",\"unpinnedSubjects\":\"$unpinned_sample\",\"dirtySubjects\":\"$dirty_sample\",\"iceCubesAppPin\":\"$icecubes_expected\",\"iceCubesAppFound\":\"$icecubes_found\",\"iceCubesAppStatus\":\"$icecubes_verdict\",\"corpusRoot\":\"$corpus_root\",\"corpusRootEntries\":$corpus_entries,\"corpusRootOverridable\":\"$corpus_root_overridable\",\"violations\":$violations}"

if [[ "${1:-}" == "--print" ]]; then
    exit 0
fi

if (( violations > 0 )); then
    print -u2 "SUBJECT-REVISIONS RED — $violations pin(s) violated"
    print -u2 "A board number is a claim about a KNOWN tree. Either restore the subject to its" \
        "pinned revision, or move the pin in its own commit and say what the move does to every" \
        "floor that scored the old one (R2_FLOORS in Scripts/icecubes-r2.sh, the IceCubesCheck" \
        "rung ladder, the ProjectCheck census)."
    exit 1
fi
print "subject revisions GREEN"
