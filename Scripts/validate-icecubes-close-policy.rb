#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

# Every tracked path in this file is REPO-RELATIVE, because most of them are
# consumed by `git show <rev>:<path>`, which git resolves against the repository
# ROOT and never against the CWD. The FILESYSTEM reads have to agree with that or
# the two halves of a comparison see different trees: `Docs/…` read through
# `File.read` while the same constant is read through `git show` gave an
# inconsistent view from any directory but the checkout root — the series looked
# absent (so the coverage check stood down) while its ancestor parsed fine. The
# anchor is this script's own location — `Scripts/` sits directly under the root
# — so it holds even where git itself cannot be run, and `repo_file` is the ONE
# place a tracked path becomes a filesystem path.
REPO_ROOT = File.expand_path("..", File.dirname(File.expand_path(__FILE__)))

def repo_file(path)
  File.join(REPO_ROOT, path)
end

POLICY_COMMIT = "b2ea7aa821237d2c0702c32f4d11c842c34da12d"
STALL_WINDOW = 5
TOTAL_PIXELS = 630_000
METRIC_PATTERN =
  /\bR2\s+(\d+)\s*->\s*(\d+)\s*\/\s*#{TOTAL_PIXELS}\b/
# Binding form:
#   STALL-ACK decomposition <screen> <branch>@<sha> microtwin <Name> AE <n> -> 0
# The July grammar hardcoded ONE frontier (`overlay-cross-import@<sha> row AE
# <n> -> 0`), so the only satisfiable ack was a decomposition of the row overlay
# — and the ledger accordingly carries 50 copies of a single 2026-07-30
# certificate, re-posted after each merge because only lines after the last
# MERGE-DONE are read. Naming the screen ties the ack to debt the board still
# measures; `verify_decomposition` dates the evidence against the stall window
# so a certificate cannot be reused past the stall it answered.
DECOMPOSITION_PATTERN =
  /\bSTALL-ACK\b[^\n]*?\bdecomposition\s+([\w-]+)\s+([\w.\/-]+)@([0-9a-f]{8,40})\b[^\n]*?\bmicrotwin\s+([A-Za-z_]\w*)[^\n]*?\bAE\s+(\d+)\s*->\s*0\b/i
MICROTWIN_SEARCH_PATH = "Tests/"
R2_BOARD_PATH = "Scripts/icecubes-r2.sh"
# The terminator is a LINE-INITIAL `)`, not the first `)` anywhere in the
# block. Floors carry prose explaining what each number is, and one of those
# comments names `.draggable(_:)` — a non-greedy scan ended the array inside
# that comment and silently dropped every screen below it.
R2_FLOORS_PATTERN = /R2_FLOORS=\((.*?)^\s*\)/m
R2_SCREENS_PATTERN = /R2_SCREENS=\(([^)]*)\)/
R2_FLOOR_ENTRY_PATTERN = /^\s*([A-Za-z][\w-]*)\s+(\d+)\s*$/
R2_COMMENT_PATTERN = /#[^\n]*/
# A screen whose residue owes no renderer fix, declared BY THE BOARD:
#   # ACKNOWLEDGED <screen>: <reason>
# `stalled?` exempts only an EXACT zero, so a board that converged to a residue
# it had already characterised as un-owed — `tags-list 2`, an anti-aliased pair
# on one edge — read as stalled forever, and the only escape (§16 STALL-ACK)
# demands a screen with POSITIVE debt: it would have forced a certificate for
# the very residue that owes nothing, which is the empty certificate §16 exists
# to refuse. The exemption is a reviewable line in the board's own diff, not a
# threshold here: a number in this file would itself be the
# measurement-calibrated constant §4 polices. Historical shas carry no marker,
# so every past landing keeps the figure it was scored with.
R2_ACKNOWLEDGED_PATTERN = /^\s*#\s*ACKNOWLEDGED\s+([A-Za-z][\w-]*)\s*:/
# Four MERGE-DONE spellings are in the ledger (`MERGE-DONE <sha>`,
# `MERGE-DONE <lane> <sha>`, a steward form, and 7-hex shorthand), so the sha is
# found by candidate rather than by position. `git show` is the arbiter: a
# candidate that does not resolve to the board is simply not a sha.
MERGE_DONE_SHA_PATTERN = /\b[0-9a-f]{7,40}\b/
MERGE_DONE_SHA_CANDIDATES = 4
MERGE_DONE_MARKER = "MERGE-DONE"
# Binding form:
#   STALL-ESCALATION <screen> — <the decision the steward owes>
# The escalation is the OTHER disposition §5 allows, and it was the only one
# read by bare substring, so any sentence containing the word escalated. It now
# names its frontier on the same terms `verify_decomposition` demands of an
# ack: a screen the board measures, whose debt is still open. An escalation of
# a converged screen asks the steward about nothing.
ESCALATION_PATTERN = /\bSTALL-ESCALATION\s+([\w-]+)/i

# ── The tracked landing series ────────────────────────────────────────────────
# Until this file existed the merge verdict was reproducible from exactly ONE
# artefact: `.claude/claims.md` — ~990 KB of prose, 214 MERGE-DONE entries, ZERO
# git history — which `Scripts/gate.sh` deliberately reads from OUTSIDE the gated
# worktree (`${git_common_dir:h}/.claude/claims.md`, gate.sh:207). A fresh clone
# could not reproduce a single close, and an audit citation into that file
# (claims.md:2418) was past EOF within hours of being written.
#
# The ledger cannot simply be tracked: `.gitignore` calls it the "Multi-agent
# claims lock — out-of-band, never merged", and several lanes append to it
# concurrently, so tracking the PROSE would make every lane conflict on every
# landing. What is committed instead is the SERIES this detector consumes — one
# line per landing, `merge=union` so parallel appends cannot conflict.
#
# The prose ledger stays the FALLBACK, and that is not a courtesy: on the day
# this landed a lane was already mid-gate on a tree that predates the series, and
# it will post a MERGE-DONE with no line to match. A landing that predates the
# series, or one a lane posted only to the ledger, is still counted.
LANDING_SERIES_PATH = "Docs/icecubes-landing-series.tsv"
# Five TAB-separated fields, anchored at both ends. `merge_done_landing` needs a
# candidate search because the ledger grew FOUR MERGE-DONE spellings; the whole
# point of a machine channel is that it has exactly one.
LANDING_SERIES_LINE_PATTERN =
  /\A([0-9a-f]{40})\t(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\t(\d+)\t(\d+)\t(\d+)\z/
LANDING_SERIES_IGNORED_PATTERN = /\A\s*(?:#|\z)/
LANDING_SERIES_FIELDS = %w[sha stamp screens owed rungs].freeze
RUNG_LADDER_PATH = "Sources/IceCubesCheck/IceCubesCheck.swift"
# The same selection `Scripts/validate-anti-drift.sh` ratchets
# (`grep -ohE '"R[0-9][a-z-]*"' … | sort -u | wc -l`), so the two instruments
# cannot disagree about what a rung is.
RUNG_PATTERN = /"R[0-9][a-z-]*"/
# How deep to read the prose ledger for landings the series does not carry. Two
# windows, so the fallback stays correct while up to STALL_WINDOW consecutive
# landings are posted to the ledger alone.
LEDGER_FALLBACK_DEPTH = STALL_WINDOW * 2
# How many of the STALL_WINDOW scored landings must come from the TRACKED series
# rather than from the untracked ledger. Measured on 2026-08-08 against the ten
# backfilled landings as 5 of 5:
#
#   /usr/bin/ruby Scripts/validate-icecubes-close-policy.rb .claude/claims.md \
#     | grep -o '"seriesWindowCoverage":[0-9]*'
#
# The floor is ONE, not five, deliberately. The wiring that appends a line at
# MERGE-DONE time lands separately from this file, and a lane already in flight
# will land a batch carrying no line at all — a floor of five would red it on
# arrival, and a ratchet that reds the work it was written to protect is a
# defect, not a win. One tolerates four consecutive unrecorded landings; what it
# catches is the series being ABANDONED and the verdict drifting back into the
# untracked ledger.
#
# IT IS REPORT-ONLY UNTIL ITS PRODUCER EXISTS, and that is the whole point of
# shipping it this way. NOTHING currently appends a line at landing time:
# `--record` exists, but no step of the landing procedure runs it, and the ten
# lines below the header of the series were BACKFILLED by hand-run commands. An
# enforced floor in that state does not police a regression — it reds every close
# from the moment it lands until somebody reads a comment, which is the failure
# this repository has recorded three times (`AUDIT-2026-07-24-execution-gap.md`,
# `AUDIT-2026-07-28-generation-leverage.md`, AGENTS.md §4/§5: a rule left as
# prose does not fire, only exit codes do). Shipping the FLOOR before the
# PRODUCER inverts that failure instead of fixing it. So a shortfall is a
# WARNING: it prints on stdout, it is in the receipt
# (`seriesWindowCoverage`, `seriesWindowCoverageFloor`,
# `seriesWindowCoverageEnforced`), and it does not exit 1.
#
# WHAT MUST BE TRUE BEFORE `..._ENFORCED` FLIPS TO true, in this order:
#
#   1. the landing procedure runs `--record <gated-sha>` beside its MERGE-DONE
#      post. NOT `Scripts/gate.sh`: it runs in a clean detached checkout whose
#      worktree it fingerprints, so a write there reports as source drift — the
#      caller that posts MERGE-DONE is the only correct place.
#   2. the newest scored landing came from the series rather than the ledger, so
#      the coverage being met is the PRODUCER working and not the backfill still
#      being inside the window. The LAST element of `landedSources` must read
#      "series":
#        /usr/bin/ruby Scripts/validate-icecubes-close-policy.rb \
#          .claude/claims.md | grep -o '"landedSources":\[[^]]*\]'
#   3. three further landings have each satisfied (2), and the coverage command
#      above then reads at or above the floor being enforced.
#
# Flip it in its own commit, quoting that command's output — the same discipline
# AGENTS.md §5 imposes on a threshold move: a measurement, not an assertion.
FLOOR_SERIES_WINDOW_COVERAGE = 1
FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED = false

def git(*arguments)
  stdout, stderr, status = Open3.capture3("git", *arguments)
  [stdout, stderr, status.success?]
end

# The pixel half of the north star, read from the board the gate ENFORCES
# rather than from claims prose. `R2_FLOORS` is a committed, ratchets-down-only
# baseline per screen, so its sum is the open pixel debt at that sha: 0 only
# when every screen is identical to the twin. Prose is not a metric channel —
# `\bR2\b.*?(\d+)/630000` scanned over a free-text sentence returns whatever
# digits happen to sit before the total (it read 124568 out of an unrelated
# clause and broke the stall window that way).
def parse_r2_floors(source)
  body = source[R2_FLOORS_PATTERN, 1]
  return nil unless body

  entries = body.gsub(R2_COMMENT_PATTERN, "").scan(R2_FLOOR_ENTRY_PATTERN)
  return nil if entries.empty?

  floors = entries.to_h { |screen, value| [screen, Integer(value, 10)] }
  # What makes the next truncation impossible to miss. `icecubes-r2.sh` already
  # refuses at RUNTIME to score a screen carrying no floor, or to hold a floor
  # for a screen it never captures; this asserts that same agreement STATICALLY.
  # A screen the parser fails to see then reads as UNREADABLE — which the tip
  # path reports as an error and fails the close — instead of as zero debt,
  # which is what let `media-browser 367681` leave the sum unnoticed.
  screens = source[R2_SCREENS_PATTERN, 1]&.split
  return nil if screens && screens.sort != floors.keys.sort

  floors
end

# nil means "this candidate is not a sha, keep looking"; :unreadable means the
# candidate IS a landing whose board would not parse. Collapsing the two let a
# window silently shrink past the truncation that caused it — the window would
# just walk further back and report five numbers as though nothing were missing.
def parse_r2_acknowledged(source)
  body = source[R2_FLOORS_PATTERN, 1]
  return [] unless body

  body.scan(R2_ACKNOWLEDGED_PATTERN).flatten
end

# The stall series measures debt that is still OWED. A screen the board has
# ACKNOWLEDGED owes no renderer fix, so leaving it in the series asks the loop
# to drive a number nobody intends to move — and then refuses every close until
# it does. The floors themselves are untouched: `icecubes-r2.sh` still enforces
# an acknowledged screen's floor, so it cannot regress, and the headline still
# prints its debt. Only the STALL predicate stops counting it.
def r2_floors_at(sha)
  source, _error, ok = git("show", "#{sha}:#{R2_BOARD_PATH}")
  return nil unless ok

  floors = parse_r2_floors(source)
  return :unreadable unless floors

  acknowledged = parse_r2_acknowledged(source)
  floors.reject { |screen, _value| acknowledged.include?(screen) }
end

# A marker is POSTED, not MENTIONED. Every real landing carries the sha it
# landed; a prose reference to one ("no MERGE-DONE follows it", "sits after the
# last MERGE-DONE") carries none, and `git show` is the arbiter of which is
# which. Recognising the marker by bare substring made a note that DESCRIBED
# the ledger indistinguishable from an entry IN it — see `last_landing_index`.
def merge_done_landing(line, resolver)
  marker = line.index(MERGE_DONE_MARKER)
  return nil unless marker

  # /usr/bin/ruby is 2.6 (no filter_map) and the gate calls it by path.
  line[marker..-1]
    .scan(MERGE_DONE_SHA_PATTERN)
    .first(MERGE_DONE_SHA_CANDIDATES)
    .each do |candidate|
      floors = resolver.call(candidate)
      next unless floors

      return { "sha" => candidate,
               "open" => floors == :unreadable ? nil : floors.values.sum }
    end
  nil
end

# Walks back from the newest claim, so only the window's worth of shas is
# resolved instead of every MERGE-DONE ever posted. Returns the landing sha
# beside its open debt — the oldest sha in the window dates the stall.
def landed_entries(lines, resolver: method(:r2_floors_at), limit: STALL_WINDOW)
  entries = []
  lines.reverse_each do |line|
    break if entries.length == limit

    landed = merge_done_landing(line, resolver)
    next unless landed

    entries << landed
  end
  entries.reverse
end

# Where the disposition window opens: dispositions are read only AFTER the last
# landing, because a merge consumes the ack or escalation that permitted it.
# This asks the same question `landed_entries` asks — did this line land a sha —
# so the two cannot disagree about what a landing is.
def last_landing_index(lines, resolver: method(:r2_floors_at))
  lines.rindex { |line| merge_done_landing(line, resolver) } || -1
end

def landed_metrics(lines, resolver: method(:r2_floors_at), limit: STALL_WINDOW)
  landed_entries(lines, resolver: resolver, limit: limit)
    .map { |entry| entry.fetch("open") }
end

def landing_series_line(entry)
  LANDING_SERIES_FIELDS.map { |field| entry.fetch(field) }.join("\t")
end

# The ONE derivation of a landing's fields, shared by `--record` (which writes
# them) and by every close (which re-derives them and compares). A recorded field
# therefore cannot drift from the tree it claims to describe, and no field is
# ever typed by hand — AGENTS.md §4's "execute the target instead of transcribing
# it", applied to the ledger.
#
# Returns [entry, nil, nil] or [nil, why-not, kind]. The KIND is load-bearing and
# was missing: FOUR distinct failures reached one caller and were all reported as
# "its recorded fields are being trusted", a sentence that is only true of ONE of
# them.
#
#   :unresolved — the sha is not an object here. That is a clone that has not
#                 fetched it, and the committed record legitimately stands.
#   :defective  — the sha RESOLVES and something the series depends on is wrong
#                 with the tree at it: undatable, no R2 board, a board that does
#                 not parse, no rung ladder. None of those is an unfetched
#                 object; every one of them means the recorded fields cannot be
#                 checked against the very tree they claim to describe, which is
#                 precisely the property the series exists to provide. A board
#                 that stops parsing is also the exact shape of the truncation
#                 that let `media-browser 367681` leave the sum unnoticed.
def derive_landing(sha)
  resolved, error, ok = git("rev-parse", "#{sha}^{commit}")
  return [nil, "not a commit in this clone: #{error.strip}", :unresolved] unless
    ok

  resolved = resolved.strip
  stamp, stamp_error, stamp_ok = git("show", "-s", "--format=%ct", resolved)
  return [nil, "could not be dated: #{stamp_error.strip}", :defective] unless
    stamp_ok

  epoch = Integer(stamp.strip, 10)
  board, board_error, board_ok = git("show", "#{resolved}:#{R2_BOARD_PATH}")
  return [nil, "carries no #{R2_BOARD_PATH}: #{board_error.strip}", :defective] \
    unless board_ok

  floors = parse_r2_floors(board)
  return [nil, "the R2 board there does not parse", :defective] unless floors

  acknowledged = parse_r2_acknowledged(board)
  ladder, ladder_error, ladder_ok =
    git("show", "#{resolved}:#{RUNG_LADDER_PATH}")
  return [nil, "carries no #{RUNG_LADDER_PATH}: #{ladder_error.strip}",
          :defective] unless ladder_ok

  owed = floors.reject { |screen, _value| acknowledged.include?(screen) }
    .values.sum
  [{ "sha" => resolved,
     "stamp" => Time.at(epoch).utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
     "epoch" => epoch,
     "screens" => floors.length,
     "owed" => owed,
     "rungs" => ladder.scan(RUNG_PATTERN).uniq.length,
     # `open` is what the stall window measures; the series records the OWED
     # sum, which is what `r2_floors_at` has returned since the board gained
     # `# ACKNOWLEDGED`. Naming it twice keeps the two channels comparable
     # without teaching the window which channel it is reading.
     "open" => owed,
     "source" => "series" }, nil, nil]
end

# `#` lines and blank lines are ignored; ANY other line is a hard error. A field
# this file cannot read is a verdict nobody can reproduce, which is the whole
# defect being fixed — silently skipping an unreadable line would reintroduce it.
def parse_landing_series(source, errors, path = LANDING_SERIES_PATH)
  entries = {}
  source.each_line.with_index(1) do |raw, number|
    line = raw.chomp
    next if line.match?(LANDING_SERIES_IGNORED_PATTERN)

    match = line.match(LANDING_SERIES_LINE_PATTERN)
    epoch =
      if match
        begin
          Time.utc(*(2..7).map { |group| Integer(match[group], 10) }).to_i
        rescue ArgumentError
          nil
        end
      end
    if epoch.nil?
      errors << "#{path}:#{number} is not a landing line (<sha40> TAB " \
        "<utcStamp> TAB <screens> TAB <owedAE> TAB <rungs>): #{line[0, 80]}"
      next
    end

    entry = {
      "sha" => match[1],
      "stamp" => "#{match[2]}-#{match[3]}-#{match[4]}T" \
        "#{match[5]}:#{match[6]}:#{match[7]}Z",
      "epoch" => epoch,
      "screens" => Integer(match[8], 10),
      "owed" => Integer(match[9], 10),
      "rungs" => Integer(match[10], 10),
      "open" => Integer(match[9], 10),
      "source" => "series"
    }
    previous = entries[entry.fetch("sha")]
    # The one shape `merge=union` can hide: two lanes append DIFFERENT lines for
    # the same landing and both survive the merge. A silent last-wins would pick
    # one at random, and "later in the file" is not a tiebreak that means
    # anything in a file whose ordering is explicitly not significant.
    if previous && landing_series_line(previous) != landing_series_line(entry)
      errors << "#{path} carries two disagreeing lines for landing " \
        "#{entry.fetch("sha")[0, 12]} (#{landing_series_line(previous)} vs " \
        "#{landing_series_line(entry)}); union merge kept both — re-derive " \
        "with --record and keep one"
    end
    entries[entry.fetch("sha")] = entry
  end
  entries.values
end

def landing_series_at(revision, path = LANDING_SERIES_PATH)
  source, _error, ok = git("show", "#{revision}:#{path}")
  return nil unless ok

  # Parse errors in an ANCESTOR are not this candidate's to answer; the
  # append-only comparison only needs the lines that read.
  parse_landing_series(source, [], path)
end

# Re-derives each recorded field from the tree at that sha and compares. This is
# what stops the series becoming a place to type numbers into: a hand-edited
# field reds the close rather than becoming history.
def verify_landing_series(
  entries, errors, path = LANDING_SERIES_PATH, deriver: method(:derive_landing)
)
  entries.each do |entry|
    derived, failure, kind = deriver.call(entry.fetch("sha"))
    if derived.nil?
      entry["verified"] = false
      if kind == :unresolved
        # THE ONLY case the trusting sentence is true of: a sha this clone
        # cannot resolve is not a forgery, it is a clone that has not fetched
        # it. The committed record stands, and the receipt says the entry was
        # trusted rather than re-derived.
        warn "#{path}: landing #{entry.fetch("sha")[0, 12]} could not be " \
          "re-derived (#{failure}); its recorded fields are being trusted"
      else
        # A sha that RESOLVES but whose tree will not yield the fields is a
        # DEFECT, not a missing object — and it was being waved through by the
        # same sentence. There is nothing to trust here: the record claims to
        # describe a tree that cannot answer for it.
        errors << "#{path}: landing #{entry.fetch("sha")[0, 12]} resolves in " \
          "this clone but #{failure}; a recorded landing must be re-derivable " \
          "from the tree at its own sha, or the series is asserting numbers " \
          "nothing can check"
      end
      next
    end

    entry["verified"] = true
    LANDING_SERIES_FIELDS.each do |field|
      next if field == "sha"
      next if derived.fetch(field) == entry.fetch(field)

      errors << "#{path}: landing #{entry.fetch("sha")[0, 12]} records " \
        "#{field} #{entry.fetch(field)}, but the tree at that sha derives " \
        "#{derived.fetch(field)} — every field here is derived, never typed " \
        "(re-run --record)"
    end
  end
end

# APPEND-ONLY, enforced rather than requested. `merge=union` is only safe for a
# file nobody rewrites, and a lane that quietly dropped a landing could move the
# stall window off the very debt it exists to measure. The comparison is against
# the MERGE BASE, not against `origin/main`: a candidate that has not yet
# absorbed the main which first introduced the file has a merge base carrying no
# series at all, and must not be accused of deleting it.
def verify_landing_series_append_only(
  ancestor_entries, entries, series_available, errors, base_label,
  path = LANDING_SERIES_PATH
)
  return if ancestor_entries.nil?

  unless series_available
    errors << "#{path} exists at merge base #{base_label} but not in the " \
      "candidate; the landing series is append-only and may not be deleted"
    return
  end

  current = {}
  entries.each { |entry| current[entry.fetch("sha")] = entry }
  ancestor_entries.each do |ancestor|
    present = current[ancestor.fetch("sha")]
    if present.nil?
      errors << "#{path} drops landing #{ancestor.fetch("sha")[0, 12]}, which " \
        "merge base #{base_label} already records; the series is append-only"
    elsif landing_series_line(present) != landing_series_line(ancestor)
      errors << "#{path} rewrites landing #{ancestor.fetch("sha")[0, 12]} " \
        "(#{landing_series_line(ancestor)} -> " \
        "#{landing_series_line(present)}); the series is append-only"
    end
  end
end

def locate_landing(sha)
  resolved, _error, ok = git("rev-parse", "#{sha}^{commit}")
  return nil unless ok

  stamp, _stamp_error, stamp_ok =
    git("show", "-s", "--format=%ct", resolved.strip)
  return nil unless stamp_ok

  [resolved.strip, Integer(stamp.strip, 10)]
end

# `merge_done_landing` recognises four MERGE-DONE spellings, including 7-hex
# shorthand, so a ledger landing and a series landing for the same commit do not
# compare equal as strings. Both channels are normalised to the 40-hex sha before
# they are unioned, or one landing would be counted twice and the window would
# silently shorten by a real landing.
def ledger_landings(
  lines, resolver: method(:r2_floors_at), locator: method(:locate_landing),
  limit: LEDGER_FALLBACK_DEPTH
)
  landed_entries(lines, resolver: resolver, limit: limit)
    .each_with_object([]) do |entry, landings|
      located = locator.call(entry.fetch("sha"))
      next unless located

      sha, epoch = located
      landings << { "sha" => sha, "epoch" => epoch,
                    "open" => entry.fetch("open"), "source" => "ledger" }
    end
end

# The window PREFERS the tracked series and falls back to the prose ledger for
# any landing the series does not carry. Keyed by the 40-hex sha, so a landing
# recorded in both channels is counted ONCE; ordered by the recorded stamp,
# because file position means nothing under `merge=union` and ledger position
# means nothing across two channels. The sha breaks stamp ties: it is total and
# identical in every clone, which "whichever line the union driver put first" is
# not.
def landing_window(series_entries, ledger_entries, limit: STALL_WINDOW)
  by_sha = {}
  ledger_entries.each { |entry| by_sha[entry.fetch("sha")] = entry }
  series_entries.each { |entry| by_sha[entry.fetch("sha")] = entry }
  by_sha.values
    .sort_by { |entry| [entry.fetch("epoch"), entry.fetch("sha")] }
    .last(limit)
end

def series_window_coverage(window)
  window.count { |entry| entry.fetch("source") == "series" }
end

# `findings` is the caller's choice of channel: `errors` once
# FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED is true, `warnings` until then. The
# measurement is identical either way, so promoting the floor is a one-line
# change at the call site and never a change to what is measured.
def check_series_coverage(window, series_available, findings)
  # A checkout that predates the series has nothing to be measured against; the
  # ledger fallback is the whole verdict there and that is correct, not a
  # violation. Deleting the file is caught by the append-only check instead.
  return unless series_available
  return if window.length < FLOOR_SERIES_WINDOW_COVERAGE

  coverage = series_window_coverage(window)
  return if coverage >= FLOOR_SERIES_WINDOW_COVERAGE

  findings << "only #{coverage} of the #{window.length} scored landings come " \
    "from #{LANDING_SERIES_PATH} (floor #{FLOOR_SERIES_WINDOW_COVERAGE}): the " \
    "merge verdict is drifting back into the untracked ledger, where no clone " \
    "can reproduce it — record each landing with `Scripts/" \
    "validate-icecubes-close-policy.rb --record <gated-sha>` beside its " \
    "MERGE-DONE post"
end

# `--record <gated-sha>` appends the landing the gate just cleared. It DERIVES
# every field, so nothing about a landing is ever typed, and it is a no-op when
# the sha is already recorded, so re-running it after a retried merge cannot
# double-count a landing. Run it AFTER the gate, beside the MERGE-DONE post:
# appending BEFORE the gate changes the tree and therefore changes the very sha
# the line describes. It must never run inside the gate's clean-detached
# checkout — `gate.sh` fingerprints the worktree and a write there reports as
# source drift.
#
# THE SHA MUST HAVE LANDED, and that is checked, not assumed. `derive_landing`
# accepts any REACHABLE commit: an abandoned lane tip, a predecessor that a
# rebase orphaned, a branch that never merged. Recording one of those writes a
# permanent line — the series is append-only, enforced — into the record the
# stall window is scored from, so the debt series would then contain iterations
# that are not on the integration history at all. The check is:
#
#   git merge-base --is-ancestor <resolved> <integration-base>
#
# with `<integration-base>` defaulting to origin/main and overridable through
# CLOSE_POLICY_INTEGRATION_BASE for a steward tree with a different remote name
# or a lane recording against a staging ref. A base that does not RESOLVE is also
# a refusal: silently skipping the check the moment the ref is missing is how the
# check stops existing.
RECORD_INTEGRATION_BASE =
  ENV.fetch("CLOSE_POLICY_INTEGRATION_BASE", "origin/main")

# Split out so the refusal can be self-tested without a checkout, and so both the
# resolution failure and the ancestry failure name the sha they are about.
def verify_landed(resolved, integration_base)
  base, base_error, base_ok = git("rev-parse", "#{integration_base}^{commit}")
  unless base_ok
    return "integration base #{integration_base} does not resolve in this " \
      "clone (#{base_error.strip}); fetch it, or name another one with " \
      "CLOSE_POLICY_INTEGRATION_BASE"
  end

  _, ancestry_error, ancestry_ok =
    git("merge-base", "--is-ancestor", resolved, base.strip)
  return nil if ancestry_ok

  detail = ancestry_error.strip.empty? ? "" : " — #{ancestry_error.strip}"
  "#{resolved} has not landed: it is not an ancestor of " \
    "#{integration_base} (#{base.strip[0, 12]})#{detail}. The landing series " \
    "is append-only, so an abandoned lane tip or a rebased predecessor " \
    "recorded here is permanent"
end

def record_landing(
  sha, path, write:, integration_base: RECORD_INTEGRATION_BASE,
  deriver: method(:derive_landing), lander: method(:verify_landed)
)
  derived, failure = deriver.call(sha)
  if derived.nil?
    warn "cannot record #{sha}: #{failure}"
    return 1
  end

  if write
    unlanded = lander.call(derived.fetch("sha"), integration_base)
    if unlanded
      warn "cannot record #{sha}: #{unlanded}"
      return 1
    end
  end

  line = landing_series_line(derived)
  # `--print-record` is PURE: it derives and prints, and says nothing about the
  # file's contents. That is what makes it usable as the check that the line
  # already in the series is the line the tree derives — a mode that answered
  # "already recorded" instead of printing could not be diffed against anything.
  # It is also why the landed check above is gated on `write`: printing what a
  # line WOULD be for a lane tip is a legitimate preview, and it is the permanent
  # append — not the derivation — that the sha has to have landed for.
  unless write
    puts line
    return 0
  end

  existing = File.file?(path) ? parse_landing_series(File.read(path), []) : []
  recorded = existing.find { |entry| entry.fetch("sha") == derived.fetch("sha") }
  if recorded
    if landing_series_line(recorded) == line
      puts "#{path} already records #{derived.fetch("sha")[0, 12]}"
      return 0
    end
    warn "#{path} records #{derived.fetch("sha")[0, 12]} as " \
      "#{landing_series_line(recorded)} but the tree derives #{line}; the " \
      "series is append-only — resolve that by hand, deliberately"
    return 1
  end

  File.open(path, "a") do |series|
    # An append onto a file whose last byte is not a newline would splice two
    # landings into one unparseable line.
    size = File.size(path)
    series.write("\n") if size.positive? && IO.binread(path, 1, size - 1) != "\n"
    series.puts(line)
  end
  puts "recorded #{line} in #{path}"
  0
end

# `positive?` is what keeps the detector honest at both ends. Without it the
# predicate degenerates the moment the tracked debt reaches 0: "did not
# decrease" is then true forever, so a CONVERGED target reports as stalled.
# With it, a green run says converged and only real open debt can stall.
def stalled?(metrics)
  window = metrics.last(STALL_WINDOW)
  window.length == STALL_WINDOW &&
    window.last.positive? &&
    window.each_cons(2).all? { |before, after| after >= before }
end

def post_policy_commits(integration_base, policy_epoch)
  output, error, ok = git(
    "log",
    "--format=%H%x1f%ct%x1f%B%x1e",
    "#{integration_base}..HEAD"
  )
  abort("could not inspect candidate commits: #{error.strip}") unless ok

  output.split("\x1e").each_with_object([]) do |record, commits|
    next if record.strip.empty?

    sha, timestamp, message = record.split("\x1f", 3)
    next unless sha && timestamp && message
    next unless Integer(timestamp, 10) > policy_epoch

    commits << { "sha" => sha.strip, "message" => message.strip }
  end
end

def decomposition_acknowledgement(lines, last_merge_done_index)
  lines.each_with_index.drop(last_merge_done_index + 1)
    .each_with_object([]) do |(line, index), matches|
      match = line.match(DECOMPOSITION_PATTERN)
      next unless match

      matches << {
        "index" => index,
        "line" => line.strip,
        "screen" => match[1],
        "branch" => match[2],
        "commit" => match[3],
        "microtwin" => match[4],
        "redAE" => Integer(match[5], 10)
      }
    end.last
end

# The escalation posted after the last landing, or nil. Reading it structurally
# is a TIGHTENING in the same stroke that stops prose from suppressing one: the
# sentence "the STALL-ESCALATION sits after the last MERGE-DONE" no longer
# escalates, and neither does an escalation of a screen already at AE 0.
def stall_escalation(lines, last_landing_index, open_by_screen)
  lines.each_with_index.drop(last_landing_index + 1)
    .each_with_object([]) do |(line, index), matches|
      screen = line[ESCALATION_PATTERN, 1]
      next unless screen
      next unless open_by_screen
      next unless open_by_screen.fetch(screen, 0).positive?

      matches << { "index" => index, "line" => line.strip, "screen" => screen }
    end.last
end

# §5 allows a stall to be dispositioned two ways, and the ledger's LATEST
# posting is the lane's current position. Preferring an ack whenever one exists
# inverts the ledger's chronology: an 11:20Z certificate outranked a 17:50Z
# escalation, and the close then failed on the STALE ack's defects while the
# escalation that superseded it went unread. Recency governs symmetrically —
# ack after escalation is verified as an ack, so this cannot be used to dodge
# `verify_decomposition` by escalating afterwards, only to supersede a
# certificate the lane no longer stands behind.
def latest_disposition(lines, last_landing_index, open_by_screen)
  acknowledgement = decomposition_acknowledgement(lines, last_landing_index)
  escalation = stall_escalation(lines, last_landing_index, open_by_screen)
  candidates = []
  candidates << { "kind" => "decomposition", "entry" => acknowledgement } if
    acknowledgement
  candidates << { "kind" => "escalation", "entry" => escalation } if escalation
  candidates.max_by { |candidate| candidate.fetch("entry").fetch("index") }
end

def verify_decomposition(
  acknowledgement, errors, open_by_screen, stall_epoch, acknowledged = []
)
  screen = acknowledgement.fetch("screen")
  branch = acknowledgement.fetch("branch")
  microtwin = acknowledgement.fetch("microtwin")

  # The ack must answer debt the board still measures — decomposing a screen
  # that already reads AE 0 discharges nothing.
  if open_by_screen
    if !open_by_screen.key?(screen)
      errors << "STALL-ACK names screen '#{screen}', which the R2 board does " \
        "not measure (#{open_by_screen.keys.join(", ")})"
    elsif acknowledged.include?(screen)
      # Without this the exemption becomes a trap: an acknowledged screen is
      # the only one left carrying positive debt, so the grammar would steer
      # every ack straight at the residue that owes nothing — §16's empty
      # certificate, arrived at by following the rules.
      errors << "STALL-ACK names screen '#{screen}', which the board " \
        "ACKNOWLEDGED as owing no renderer fix; it cannot discharge a stall"
    elsif !open_by_screen.fetch(screen).positive?
      errors << "STALL-ACK names screen '#{screen}', already converged at " \
        "AE 0; decompose a screen that still carries open debt"
    end
  end

  remote_tip, remote_error, remote_ok = git(
    "rev-parse", "refs/remotes/origin/#{branch}"
  )
  unless remote_ok
    errors << "#{branch} is not available as a pushed remote ref " \
      "(§10: the frontier does not live in a stash): #{remote_error.strip}"
    return nil
  end

  evidence_sha, evidence_error, evidence_ok = git(
    "rev-parse", "#{acknowledgement.fetch("commit")}^{commit}"
  )
  unless evidence_ok
    errors << "STALL-ACK decomposition commit is unavailable: " \
      "#{evidence_error.strip}"
    return nil
  end
  evidence_sha = evidence_sha.strip

  _, ancestry_error, ancestry_ok = git(
    "merge-base", "--is-ancestor", evidence_sha, remote_tip.strip
  )
  unless ancestry_ok
    errors << "STALL-ACK decomposition commit is not retained by " \
      "origin/#{branch}: #{ancestry_error.strip}"
  end

  # A certificate cannot be re-pledged: the evidence must POSTDATE the stall it
  # answers, or one old decomposition clears every future stall by copy-paste.
  stamp, stamp_error, stamp_ok = git("show", "-s", "--format=%ct", evidence_sha)
  if !stamp_ok
    errors << "could not date the STALL-ACK evidence commit: " \
      "#{stamp_error.strip}"
  elsif stall_epoch && Integer(stamp.strip, 10) <= stall_epoch
    errors << "STALL-ACK evidence #{evidence_sha[0, 12]} predates the stall " \
      "window it answers; decompose the CURRENT frontier"
  end

  _, grep_error, grep_ok = git(
    "grep", "--quiet", "--fixed-strings", "func #{microtwin}",
    evidence_sha, "--", MICROTWIN_SEARCH_PATH
  )
  unless grep_ok
    errors << "STALL-ACK decomposition commit carries no microtwin " \
      "'func #{microtwin}' under #{MICROTWIN_SEARCH_PATH}: " \
      "#{grep_error.strip}"
  end

  {
    "screen" => screen,
    "branch" => branch,
    "commit" => evidence_sha,
    "remoteTip" => remote_tip.strip,
    "redAE" => acknowledgement.fetch("redAE"),
    "greenAE" => 0,
    "microtwin" => microtwin
  }
end

def policy_payload(
  integration_base:, commits:, metrics:, stall_active:, decomposition:, errors:,
  open_by_screen: nil, escalation: nil, landings: [], series_landings: 0,
  series_available: true, ledger_available: true, warnings: []
)
  payload = {
    # 3 adds the landing-series provenance below. The receipt reads `version`,
    # `status` and `errors`; everything else is for the reader who has to work
    # out, months later, WHICH landings a verdict was taken over.
    "version" => 3,
    "status" => errors.empty? ? "passed" : "failed",
    "integrationBase" => integration_base,
    "policyCommit" => POLICY_COMMIT,
    "checkedCommits" => commits.map { |commit| commit.fetch("sha") },
    # Named for what it actually is. Every element — landed entries AND the
    # gated tip — is the sum over screens the board did NOT mark
    # `# ACKNOWLEDGED`. It said "all-screens" while the landed entries had
    # excluded acknowledged screens since 2026-08-03, which is the same
    # scale confusion that put a TOTAL tip on an OWED window.
    "landedR2Metric" => "owed-ae-sum-unacknowledged-screens",
    "landedR2Tail" => metrics.last(STALL_WINDOW),
    # The provenance of the verdict: which shas were scored, and whether each
    # came from the TRACKED series (reproducible from a clone) or from the
    # untracked prose ledger (reproducible only on the steward's disk).
    "landingSeriesPath" => LANDING_SERIES_PATH,
    "landingSeriesAvailable" => series_available,
    "landingSeriesLandings" => series_landings,
    "ledgerAvailable" => ledger_available,
    "landedShas" => landings.map { |entry| entry.fetch("sha")[0, 12] },
    "landedSources" => landings.map { |entry| entry.fetch("source") },
    "seriesWindowCoverage" => series_window_coverage(landings),
    "seriesWindowCoverageFloor" => FLOOR_SERIES_WINDOW_COVERAGE,
    # Whether that floor EXITS or merely reports. A receipt that carried the
    # number and the floor but not this would read as an enforced ratchet to
    # anyone auditing it later, which is the same "prose says it is binding"
    # confusion the floor's own comment is about.
    "seriesWindowCoverageEnforced" => FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED,
    # Findings that did NOT fail the close. `gate.sh` only cats this log when
    # the stage is non-zero and deletes the scratch on a green run, so a warning
    # that lives only on stdout is a warning nobody reads; it goes in the
    # receipt, which is retained.
    "warnings" => warnings,
    "stallWindow" => STALL_WINDOW,
    "stallActive" => stall_active,
    # An escalated stall is not an unacknowledged one. Collapsing the two made
    # the receipt say nobody had answered the detector at the exact moment a
    # lane was asking the steward a question, so the answer lived only in
    # prose — the channel this policy exists to stop trusting.
    "stallDisposition" =>
      if !stall_active
        "not-stalled"
      elsif decomposition
        "decomposition"
      elsif escalation
        "escalation"
      else
        "unacknowledged"
      end,
    "errors" => errors
  }
  # nil is not plist-representable, so an absent breakdown is an absent key.
  if open_by_screen
    payload["r2Open"] = open_by_screen.values.sum
    payload["r2OpenByScreen"] = open_by_screen
  end
  payload["decomposition"] = decomposition if decomposition
  payload["escalation"] = escalation if escalation
  payload
end

def assert_plist_representable(payload)
  Tempfile.create(["icecubes-close-policy", ".plist"]) do |receipt|
    receipt.close
    _, create_error, created = Open3.capture3(
      "/usr/bin/plutil", "-create", "xml1", receipt.path
    )
    raise "could not create receipt fixture: #{create_error.strip}" unless
      created.success?

    _, source_error, source_inserted = Open3.capture3(
      "/usr/bin/plutil", "-insert", "source", "-dictionary", receipt.path
    )
    raise "could not create receipt source fixture: #{source_error.strip}" unless
      source_inserted.success?

    _, insert_error, inserted = Open3.capture3(
      "/usr/bin/plutil",
      "-insert", "source.iceCubesClosePolicy",
      "-json", JSON.generate(payload),
      receipt.path
    )
    raise "close-policy payload is not plist-representable: " \
      "#{insert_error.strip}" unless inserted.success?
  end
end

def self_test
  board = <<~BOARD
    typeset -A R2_FLOORS
    R2_FLOORS=(
      timeline 0
      status-detail 50184
      account-header 35241
    )
    typeset -A R2_AE_LINES
  BOARD
  raise "board floor parsing failed" unless parse_r2_floors(board) ==
    { "timeline" => 0, "status-detail" => 50_184, "account-header" => 35_241 }
  raise "a board without floors must not parse" if
    parse_r2_floors("typeset -A R2_AE_LINES\n")

  # The converged-with-an-acknowledged-residue case, which `positive?` alone
  # could not tell from a stall.
  acked_board = <<~BOARD
    typeset -A R2_FLOORS
    R2_FLOORS=(
      timeline 0
      tags-list 2
      # ACKNOWLEDGED tags-list: an anti-aliased pair on one edge, no fix owed.
    )
    R2_SCREENS=(timeline tags-list)
  BOARD
  raise "acknowledged marker not parsed" unless
    parse_r2_acknowledged(acked_board) == ["tags-list"]
  raise "an unmarked board must acknowledge nothing" unless
    parse_r2_acknowledged(board).empty?
  raise "acknowledgement must not remove the screen from the board" unless
    parse_r2_floors(acked_board) == { "timeline" => 0, "tags-list" => 2 }
  owed = parse_r2_floors(acked_board)
    .reject { |screen, _v| parse_r2_acknowledged(acked_board).include?(screen) }
  raise "owed debt must exclude the acknowledged screen" unless
    owed.values.sum.zero?
  raise "a board converged to an acknowledged residue must not stall" if
    stalled?(Array.new(STALL_WINDOW, owed.values.sum))
  raise "the same residue UNacknowledged must still stall" unless
    stalled?(Array.new(STALL_WINDOW, parse_r2_floors(acked_board).values.sum))
  # THE TIP IS ON THE WINDOW'S SCALE. Every LANDED entry is an owed sum, so the
  # gated tip must be one too. Appending the TOTAL turned a window of zeros plus
  # an acknowledged-only residue into [0,0,0,0,0] + [2] — a rising window, and
  # therefore a stall that nothing could ever clear, on a board that owes
  # nothing. The second assertion is the defect itself, kept so the fix cannot
  # be undone silently.
  raise "an acknowledged-only tip on a converged window must not stall" if
    stalled?(Array.new(STALL_WINDOW, 0) + [owed.values.sum])
  raise "the TOTAL tip is what used to fake that stall" unless
    stalled?(Array.new(STALL_WINDOW, 0) +
      [parse_r2_floors(acked_board).values.sum])

  # The shape that actually shipped: floors annotated with prose, one comment
  # naming `.draggable(_:)`. Terminating the array at the first `)` ended it
  # INSIDE that comment, so `media-browser` left the sum and the close reported
  # `R2 open 2 AE` against a real debt of 367683. The fixture above could not
  # catch it because it carries no comments at all.
  commented = <<~BOARD
    R2_SCREENS=(timeline tags-list media-browser)
    typeset -A R2_FLOORS
    R2_FLOORS=(
      timeline 0
      # Was 4. Two of those pixels were the twin encoding Display P3 16bpc.
      tags-list 2
      # Was 367861, of which 197 px were the `.draggable(_:)` error label.
      media-browser 367681
    )
    typeset -A R2_AE_LINES
  BOARD
  raise "a `)` inside a floor comment truncated the board" unless
    parse_r2_floors(commented) ==
      { "timeline" => 0, "tags-list" => 2, "media-browser" => 367_681 }

  # A floor the parser cannot see must read as UNREADABLE, never as no debt:
  # `R2_SCREENS` names a screen the floors do not, so the sum would be short.
  raise "floors disagreeing with R2_SCREENS must not parse" if
    parse_r2_floors(<<~BOARD)
      R2_SCREENS=(timeline media-browser)
      R2_FLOORS=(
        timeline 0
      )
    BOARD

  shas = Array.new(6) { |index| (index + 1).to_s * 40 }
  floors_by_sha = {
    shas[0] => { "timeline" => 0, "a" => 60_000 },
    shas[1] => { "timeline" => 0, "a" => 59_000 },
    shas[2] => { "timeline" => 0, "a" => 59_000 },
    shas[3] => { "timeline" => 0, "a" => 59_000 },
    shas[4] => { "timeline" => 0, "a" => 59_000 },
    shas[5] => { "timeline" => 0, "a" => 59_000 }
  }
  sample = shas.map { |sha| "t lane MERGE-DONE #{sha} main x -> y" }
  resolver = ->(sha) { floors_by_sha[sha] }
  raise "landed metric parsing failed" unless
    landed_metrics(sample, resolver: resolver) ==
      [59_000, 59_000, 59_000, 59_000, 59_000]
  raise "an unresolvable sha must be skipped, not counted" unless
    landed_metrics(
      sample + ["t lane MERGE-DONE #{"f" * 40} main x -> y"],
      resolver: resolver
    ) == [59_000, 59_000, 59_000, 59_000, 59_000]
  raise "prose digits must not reach the metric" unless
    landed_metrics(
      ["t lane MERGE-DONE x R2 exact 59000/630000"], resolver: resolver
    ).empty?

  raise "equal tail should stall" unless
    stalled?(landed_metrics(sample, resolver: resolver))
  raise "decreasing tail must not stall" if stalled?(
    [60_000, 60_000, 59_000, 59_000, 58_000])
  raise "a converged target must read converged, not stalled" if
    stalled?(Array.new(STALL_WINDOW, 0))
  raise "a screen still open must stall even beside a converged one" unless
    stalled?(Array.new(STALL_WINDOW, 85_425))
  # The window ends at the tip being gated: a flat landed tail plus a tip that
  # drives the debt down is the shape of a stall being CLEARED, not a stall.
  raise "a tip that decreases the debt must clear the stall" if
    stalled?(Array.new(STALL_WINDOW, 85_425) + [35_241])
  raise "a tip that holds the debt must not clear the stall" unless
    stalled?(Array.new(STALL_WINDOW, 85_425) + [85_425])
  raise "literal metric accepted incorrectly" unless
    "Metric delta: R2 59695 -> 59695 / 630000".match?(METRIC_PATTERN)
  raise "nonliteral metric accepted" if
    "Metric delta: R2 AE 59695 -> 59695 / 630000".match?(METRIC_PATTERN)

  ack_line = "t lane STALL-ACK decomposition status-detail " \
    "status-detail-caption@abcdef12 microtwin captionMatchesNativePixels " \
    "AE 1228 -> 0"
  acknowledgement = decomposition_acknowledgement(
    ["t lane MERGE-DONE x", ack_line], 0
  )
  raise "decomposition acknowledgement parsing failed" unless
    acknowledgement == {
      "index" => 1,
      "line" => ack_line,
      "screen" => "status-detail",
      "branch" => "status-detail-caption",
      "commit" => "abcdef12",
      "microtwin" => "captionMatchesNativePixels",
      "redAE" => 1228
    }
  raise "the retired single-frontier ack form must no longer parse" unless
    decomposition_acknowledgement(
      [
        "t lane MERGE-DONE x",
        "t lane STALL-ACK decomposition overlay-cross-import@abcdef12 " \
          "row AE 1228 -> 0"
      ],
      0
    ).nil?

  # A marker is POSTED, not MENTIONED. Both halves of the disposition scan
  # keyed off a bare substring, so a note that DESCRIBED the ledger read as an
  # entry IN it: `.claude/claims.md:1300` wrote "the 17:50Z STALL-ESCALATION
  # sits after the last MERGE-DONE" and thereby moved the last-landing index
  # PAST the escalation two lines above it, reporting the close as
  # unacknowledged while a valid escalation stood. Every real landing carries
  # the sha it landed; every prose reference to one does not.
  open_debt = { "timeline" => 0, "media-browser" => 367_681 }
  prose = "t lane PROGRESS — the STALL-ESCALATION sits after the last " \
    "MERGE-DONE, so the batch is landable on it"
  described = [
    "t lane MERGE-DONE #{shas[0]} main x -> y",
    "t lane STALL-ESCALATION media-browser — steward: quarantine or board?",
    prose
  ]
  raise "a prose mention of MERGE-DONE must not end the disposition window" \
    unless last_landing_index(described, resolver: resolver) == 0
  raise "a posted escalation must survive prose that mentions it" unless
    stall_escalation(described, 0, open_debt)
  raise "a prose mention must not itself escalate" if
    stall_escalation([prose], -1, open_debt)
  raise "an escalation must name a screen the board measures" if
    stall_escalation(
      ["t lane STALL-ESCALATION sideways — not a screen"], -1, open_debt
    )
  raise "an escalation naming a converged screen discharges nothing" if
    stall_escalation(
      ["t lane STALL-ESCALATION timeline — nothing open here"], -1, open_debt
    )
  raise "an escalation before the last landing is already consumed" if
    stall_escalation(
      [
        "t lane STALL-ESCALATION media-browser — steward?",
        "t lane MERGE-DONE #{shas[0]} main x -> y"
      ],
      1,
      open_debt
    )

  # Recency governs, symmetrically. An ack was preferred whenever one existed,
  # so an 11:20Z certificate outranked a 17:50Z escalation and the close failed
  # on the STALE ack's defects — a lane could not withdraw a certificate it no
  # longer stood behind. The mirror case is what keeps that from being a dodge:
  # an ack posted after an escalation is still verified as an ack.
  landing = "t lane MERGE-DONE #{shas[0]} main x -> y"
  escalation_line = "t lane STALL-ESCALATION media-browser — steward?"
  raise "the later escalation must govern an earlier ack" unless
    latest_disposition(
      [landing, ack_line, escalation_line], 0, open_debt
    ).fetch("kind") == "escalation"
  raise "the later ack must govern an earlier escalation" unless
    latest_disposition(
      [landing, escalation_line, ack_line], 0, open_debt
    ).fetch("kind") == "decomposition"
  raise "no disposition after the landing must read as none" unless
    latest_disposition([landing], 0, open_debt).nil?

  # ── The tracked landing series ────────────────────────────────────────────
  # Everything below runs on in-memory fixtures: the suite invokes this
  # self-test as a bare process, so nothing here may depend on the CWD being a
  # checkout or on git resolving a sha.
  series_text = <<~SERIES
    # a comment line, and the blank line below it, are not landings

    #{"a" * 40}\t2026-08-07T13:31:49Z\t10\t441\t9
    #{"b" * 40}\t2026-08-08T04:16:31Z\t10\t2\t9
  SERIES
  series_errors = []
  series = parse_landing_series(series_text, series_errors)
  raise "a well-formed landing series must parse clean: #{series_errors}" unless
    series_errors.empty?
  raise "comments and blank lines are not landings" unless series.length == 2
  raise "landing fields parsed wrongly" unless series.first == {
    "sha" => "a" * 40, "stamp" => "2026-08-07T13:31:49Z",
    "epoch" => Time.utc(2026, 8, 7, 13, 31, 49).to_i,
    "screens" => 10, "owed" => 441, "rungs" => 9, "open" => 441,
    "source" => "series"
  }
  # `--record` writes what `landing_series_line` renders and the close reads it
  # back with the parser above; if those two ever disagree the series becomes
  # unreadable one landing at a time.
  raise "a recorded line must round-trip through the parser" unless
    parse_landing_series("#{landing_series_line(series.first)}\n", []).first
      .fetch("owed") == 441

  malformed = []
  parse_landing_series("#{"c" * 40}\t2026-08-08T04:16:31Z\t10\t2\n", malformed)
  raise "a short landing line must be a HARD error, never a skipped line" if
    malformed.empty?
  impossible = []
  parse_landing_series("#{"c" * 40}\t2026-13-40T04:16:31Z\t10\t2\t9\n",
                       impossible)
  raise "an impossible calendar stamp must not become an epoch" if
    impossible.empty?

  duplicate = []
  parse_landing_series(
    "#{"a" * 40}\t2026-08-07T13:31:49Z\t10\t441\t9\n" \
    "#{"a" * 40}\t2026-08-07T13:31:49Z\t10\t442\t9\n", duplicate
  )
  raise "two disagreeing lines for one landing — the one shape union merge " \
    "can hide — must be an error" if duplicate.empty?
  agreeing = []
  raise "the identical line twice is a union-merge artefact, not a conflict" \
    unless parse_landing_series(
      "#{"a" * 40}\t2026-08-07T13:31:49Z\t10\t441\t9\n" \
      "#{"a" * 40}\t2026-08-07T13:31:49Z\t10\t441\t9\n", agreeing
    ).length == 1 && agreeing.empty?

  # ORDERING IS NOT SIGNIFICANT: `merge=union` may interleave two lanes'
  # appends in any order, so the window must come out identical from a file
  # whose lines are reversed.
  shuffled = parse_landing_series(series_text.lines.reverse.join, [])
  raise "file position must not decide the window" unless
    landing_window(shuffled, [], limit: 1).map { |entry| entry.fetch("sha") } ==
      landing_window(series, [], limit: 1).map { |entry| entry.fetch("sha") }

  # THE IN-FLIGHT-LANE CASE, and the reason the prose ledger stays a fallback: a
  # lane gating a tree that predates the series posts a MERGE-DONE with no line
  # to match. That landing must still be scored, and it must still LAND.
  ledger_only = { "sha" => "d" * 40, "epoch" => Time.utc(2026, 8, 8, 6).to_i,
                  "open" => 2, "source" => "ledger" }
  merged = landing_window(series, [ledger_only])
  raise "a landing the series does not carry must still be scored" unless
    merged.map { |entry| entry.fetch("sha") } == ["a" * 40, "b" * 40, "d" * 40]
  raise "a ledger-only landing must be marked as such in the receipt" unless
    merged.last.fetch("source") == "ledger"
  raise "a ledger-only landing must not stall a window that decreases" if
    stalled?(merged.map { |entry| entry.fetch("open") })

  # The same landing in BOTH channels is ONE landing. The ledger's MERGE-DONE
  # spellings include 7-hex shorthand, so the channels only dedupe after both
  # are normalised to the 40-hex sha; without that the window silently loses a
  # real landing off its old end.
  both = landing_window(
    series,
    [{ "sha" => "a" * 40, "epoch" => Time.utc(2026, 8, 7, 13, 31, 49).to_i,
       "open" => 999, "source" => "ledger" }]
  )
  raise "a landing recorded in both channels must be counted once" unless
    both.length == 2
  raise "the tracked series must win over the prose ledger" unless
    both.first.fetch("open") == 441 && both.first.fetch("source") == "series"

  append_only = []
  verify_landing_series_append_only(
    series,
    series + [{ "sha" => "e" * 40, "stamp" => "2026-08-08T09:00:00Z",
                "epoch" => Time.utc(2026, 8, 8, 9).to_i, "screens" => 10,
                "owed" => 0, "rungs" => 9, "open" => 0, "source" => "series" }],
    true, append_only, "base"
  )
  raise "appending must be allowed: #{append_only}" unless append_only.empty?
  dropped = []
  verify_landing_series_append_only(series, [series.first], true, dropped,
                                    "base")
  raise "dropping a recorded landing must be refused" if dropped.empty?
  rewritten = []
  verify_landing_series_append_only(
    series, [series.first, series.last.merge("owed" => 3)], true, rewritten,
    "base"
  )
  raise "rewriting a recorded landing must be refused" if rewritten.empty?
  deleted = []
  verify_landing_series_append_only(series, [], false, deleted, "base")
  raise "deleting the series outright must be refused" if deleted.empty?
  predating = []
  verify_landing_series_append_only(nil, [], false, predating, "base")
  raise "a merge base that predates the series must accuse nobody" unless
    predating.empty?

  covered = []
  check_series_coverage(merged, true, covered)
  raise "a window still backed by the series must not fire the floor" unless
    covered.empty?
  ledger_window = Array.new(STALL_WINDOW) do |index|
    { "sha" => index.to_s * 40, "epoch" => index, "open" => 2,
      "source" => "ledger" }
  end
  starved = []
  check_series_coverage(ledger_window, true, starved)
  raise "a window with no tracked landing at all must fire the floor" if
    starved.empty?
  unavailable = []
  check_series_coverage(ledger_window, false, unavailable)
  raise "a checkout that predates the series must not fire the floor" unless
    unavailable.empty?
  # The floor is REPORT-ONLY until its producer exists, and that has to be a
  # fact about the code rather than a claim in a comment: the call site routes
  # the finding into `warnings`, so a `check_series_coverage` that started
  # writing into `errors` regardless of the channel it was handed would ship an
  # exit-1 ratchet nothing satisfies.
  routed_errors = []
  routed_warnings = []
  check_series_coverage(
    ledger_window, true,
    FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED ? routed_errors : routed_warnings
  )
  if FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED
    raise "an ENFORCED coverage floor must reach the error channel" if
      routed_errors.empty?
  else
    raise "a report-only coverage floor must not reach the error channel" \
      unless routed_errors.empty?
    raise "a report-only coverage floor must still be REPORTED" if
      routed_warnings.empty?
  end

  # ── verify_landing_series splits its failures ─────────────────────────────
  # FOUR derive_landing failures reached one branch and were all reported as
  # "its recorded fields are being trusted". That sentence is true of exactly
  # one of them. A sha this clone has not FETCHED is a missing object and the
  # record stands; a sha that RESOLVES and whose board will not parse is a
  # defect, and trusting it is trusting numbers nothing can check.
  unfetched = []
  unfetched_entry = { "sha" => "a" * 40, "stamp" => "2026-08-07T13:31:49Z",
                      "epoch" => 0, "screens" => 10, "owed" => 441,
                      "rungs" => 9, "open" => 441, "source" => "series" }
  verify_landing_series(
    [unfetched_entry], unfetched, "series",
    deriver: ->(_sha) { [nil, "not a commit in this clone: x", :unresolved] }
  )
  raise "an unfetched landing must be trusted, not accused" unless
    unfetched.empty?
  raise "an unverified landing must say so in the receipt" if
    unfetched_entry.fetch("verified")
  defective = []
  verify_landing_series(
    [unfetched_entry.dup], defective, "series",
    deriver: ->(_sha) { [nil, "the R2 board there does not parse", :defective] }
  )
  raise "a landing that RESOLVES but will not re-derive must be an error" if
    defective.empty?
  drifted = []
  verify_landing_series(
    [unfetched_entry.dup], drifted, "series",
    deriver: lambda { |sha|
      [{ "sha" => sha, "stamp" => "2026-08-07T13:31:49Z", "epoch" => 0,
         "screens" => 10, "owed" => 442, "rungs" => 9, "open" => 442,
         "source" => "series" }, nil, nil]
    }
  )
  raise "a recorded field that disagrees with its tree must be an error" if
    drifted.empty?

  # ── `--record` refuses a sha that never landed ────────────────────────────
  # `derive_landing` accepts any REACHABLE commit — an abandoned lane tip, a
  # predecessor a rebase orphaned — and the append-only rule then makes the
  # entry permanent, so the debt series would carry iterations that are not on
  # the integration history at all.
  landed_line = landing_series_line(series.first)
  Tempfile.create(["icecubes-landing-series", ".tsv"]) do |scratch|
    scratch.close
    derived = lambda { |_sha| [series.first, nil, nil] }
    refused = record_landing(
      "abandoned", scratch.path, write: true, deriver: derived,
      lander: ->(_resolved, _base) { "not an ancestor of origin/main" }
    )
    raise "recording a sha that never landed must exit non-zero" unless
      refused == 1
    raise "a refused record must not have written anything" unless
      File.read(scratch.path).empty?
    accepted = record_landing(
      "landed", scratch.path, write: true, deriver: derived,
      lander: ->(_resolved, _base) { nil }
    )
    raise "recording a landed sha must succeed" unless accepted.zero?
    raise "a recorded landing must be the derived line" unless
      File.read(scratch.path).strip == landed_line
    # `--print-record` derives without appending, so the landed check is scoped
    # to the WRITE: previewing the line for a lane tip stays legitimate.
    previewed = record_landing(
      "abandoned", scratch.path, write: false, deriver: derived,
      lander: ->(_resolved, _base) { raise "--print-record must not ask" }
    )
    raise "--print-record must not require the sha to have landed" unless
      previewed.zero?
  end

  # The ledger normalisation, with the locator stubbed: a 7-hex MERGE-DONE and a
  # 40-hex series line for the SAME commit must collapse to one landing.
  short_ledger = ledger_landings(
    ["t lane MERGE-DONE #{("a" * 40)[0, 7]} main x -> y"],
    resolver: ->(_sha) { { "timeline" => 7 } },
    locator: ->(_sha) { ["a" * 40, Time.utc(2026, 8, 7, 13, 31, 49).to_i] }
  )
  raise "a 7-hex ledger landing must normalise to its 40-hex sha" unless
    short_ledger.map { |entry| entry.fetch("sha") } == ["a" * 40]
  raise "a normalised ledger landing must dedupe against the series" unless
    landing_window(series, short_ledger).length == 2

  series_payload = policy_payload(
    integration_base: "origin/main",
    commits: [],
    metrics: [2],
    stall_active: false,
    decomposition: nil,
    errors: [],
    landings: merged,
    series_landings: series.length,
    series_available: true,
    ledger_available: false,
    warnings: ["a finding that reports but does not fail"]
  )
  raise "the receipt must name which landings were scored" unless
    series_payload.fetch("landedShas") ==
      [("a" * 12), ("b" * 12), ("d" * 12)]
  raise "the receipt must name the channel each landing came from" unless
    series_payload.fetch("landedSources") == %w[series series ledger]
  raise "the receipt must carry the series coverage it was floored against" \
    unless series_payload.fetch("seriesWindowCoverage") == 2 &&
      series_payload.fetch("seriesWindowCoverageFloor") ==
        FLOOR_SERIES_WINDOW_COVERAGE
  # An auditor reading a floor beside a number will assume it EXITS unless the
  # receipt says otherwise, which is the same confusion the floor's comment is
  # about — one level down, in the artefact that outlives the run.
  raise "the receipt must say whether that floor exits or only reports" unless
    series_payload.fetch("seriesWindowCoverageEnforced") ==
      FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED
  raise "a warning that fails nothing must still survive into the receipt" \
    unless series_payload.fetch("warnings").length == 1 &&
      series_payload.fetch("status") == "passed"
  assert_plist_representable(series_payload)

  escalated_payload = policy_payload(
    integration_base: "origin/main",
    commits: [],
    metrics: Array.new(STALL_WINDOW, 367_683),
    stall_active: true,
    decomposition: nil,
    errors: [],
    escalation: { "index" => 2, "line" => escalation_line,
                  "screen" => "media-browser" }
  )
  raise "an escalated stall must not report as unacknowledged" unless
    escalated_payload.fetch("stallDisposition") == "escalation"
  assert_plist_representable(escalated_payload)

  unstalled_payload = policy_payload(
    integration_base: "origin/main",
    commits: [],
    metrics: [59_695],
    stall_active: false,
    decomposition: nil,
    errors: []
  )
  raise "absent decomposition must be omitted" if
    unstalled_payload.key?("decomposition")
  raise "absent breakdown must be omitted" if
    unstalled_payload.key?("r2OpenByScreen")
  assert_plist_representable(unstalled_payload)

  breakdown_payload = policy_payload(
    integration_base: "origin/main",
    commits: [],
    metrics: [85_425],
    stall_active: false,
    decomposition: nil,
    errors: [],
    open_by_screen: parse_r2_floors(board)
  )
  raise "open debt must be summed across every screen" unless
    breakdown_payload.fetch("r2Open") == 85_425
  assert_plist_representable(breakdown_payload)

  decomposition = {
    "screen" => "status-detail",
    "branch" => "status-detail-caption",
    "commit" => "abcdef12",
    "remoteTip" => "abcdef123456",
    "redAE" => 1228,
    "greenAE" => 0,
    "microtwin" => "captionMatchesNativePixels"
  }
  stalled_payload = policy_payload(
    integration_base: "origin/main",
    commits: [],
    metrics: Array.new(STALL_WINDOW, 59_695),
    stall_active: true,
    decomposition: decomposition,
    errors: []
  )
  raise "present decomposition must be retained" unless
    stalled_payload.fetch("decomposition") == decomposition
  assert_plist_representable(stalled_payload)

  puts "@@icecubes-close-policy-self-test passed"
end

if ARGV == ["--self-test"]
  self_test
  exit 0
end

# `--print-record` is the non-mutating twin of `--record`: it prints the line
# `--record` would append and touches nothing, so the derivation can be checked
# from inside a gate, a review, or a machine that must not write.
if ARGV.length.between?(2, 3) &&
   %w[--record --print-record].include?(ARGV.fetch(0))
  # The default is repo-anchored for the same reason every other tracked path
  # is: `--record` run from `Scripts/` must append to the ONE series, not create
  # a second one beside itself. An explicitly supplied path stays as given.
  exit record_landing(
    ARGV.fetch(1), ARGV.fetch(2, repo_file(LANDING_SERIES_PATH)),
    write: ARGV.fetch(0) == "--record"
  )
end

unless ARGV.length.between?(1, 2)
  warn "usage: #{$PROGRAM_NAME} CLAIMS_PATH [INTEGRATION_BASE]"
  warn "       #{$PROGRAM_NAME} --record|--print-record SHA [SERIES_PATH]"
  warn "       #{$PROGRAM_NAME} --self-test"
  warn ""
  warn "environment:"
  warn "  CLOSE_POLICY_ALLOW_MISSING_LEDGER=1  take the window from " \
    "#{LANDING_SERIES_PATH} alone when CLAIMS_PATH does not exist " \
    "(default: a missing ledger is a hard refusal)"
  warn "  CLOSE_POLICY_INTEGRATION_BASE=<rev>  what --record requires the " \
    "recorded sha to be an ancestor of (default: origin/main)"
  exit 2
end

claims_path = ARGV.fetch(0)
integration_base = ARGV.fetch(1, "origin/main")
errors = []
# Findings that report but do not fail. Nothing may be moved in here to quiet a
# red: a warning is for a measurement whose ENFORCEMENT is not yet safe (see
# FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED), never for one that is inconvenient.
warnings = []

series_file = repo_file(LANDING_SERIES_PATH)
series_available = File.file?(series_file)
series_entries =
  series_available ? parse_landing_series(File.read(series_file), errors) : []
merge_base, _merge_base_error, merge_base_ok =
  git("merge-base", integration_base, "HEAD")
ancestor_series = merge_base_ok ? landing_series_at(merge_base.strip) : nil
verify_landing_series_append_only(
  ancestor_series, series_entries, series_available, errors,
  merge_base_ok ? merge_base.strip[0, 12] : "the merge base"
)

# A missing ledger STAYS a hard exit by default. With a tracked series covering
# the window the verdict is decidable from a clone, so the degrade is now
# *possible* — but making it automatic would be a silent weakening in the least
# visible place there is: `Scripts/gate.sh` cats this log only when the stage is
# non-zero and rm -rf's the scratch on a green run, so a ledger that went missing
# by ACCIDENT (a steward checkout moved, `git_common_dir` resolving somewhere
# else, a lane invoking the wrong path) would produce a green close whose warning
# nobody would ever see. An accident must still red; only a caller that KNOWS
# there is no ledger — a fresh-clone reproducibility probe — may take the
# series-only verdict, and it says so:
#
#   CLOSE_POLICY_ALLOW_MISSING_LEDGER=1 /usr/bin/ruby \
#     Scripts/validate-icecubes-close-policy.rb .claude/claims.md
#
# Even then it is fatal when the series cannot carry the window on its own,
# because then nothing can be measured; and a STALL still cannot be
# dispositioned from a clone, since acks and escalations are posted only in the
# prose.
ALLOW_MISSING_LEDGER = ENV["CLOSE_POLICY_ALLOW_MISSING_LEDGER"] == "1"
ledger_available = File.file?(claims_path)
unless ledger_available
  unless ALLOW_MISSING_LEDGER
    warn "IceCubes claims ledger is unavailable: #{claims_path} — the merge " \
      "verdict is not being taken. If this is deliberate (a fresh-clone probe " \
      "with no steward ledger), re-run with " \
      "CLOSE_POLICY_ALLOW_MISSING_LEDGER=1 to take the window from " \
      "#{LANDING_SERIES_PATH} alone."
    exit 1
  end
  if series_entries.length < STALL_WINDOW
    warn "IceCubes claims ledger is unavailable (#{claims_path}) and " \
      "#{LANDING_SERIES_PATH} carries only #{series_entries.length} of the " \
      "#{STALL_WINDOW} landings the stall window needs"
    exit 1
  end
  warn "IceCubes claims ledger is unavailable (#{claims_path}); the landing " \
    "window is being taken from #{LANDING_SERIES_PATH} alone. STALL " \
    "dispositions are posted only in the ledger, so a stall cannot be " \
    "acknowledged from here."
end

policy_timestamp, policy_error, policy_ok = git(
  "show", "-s", "--format=%ct", POLICY_COMMIT
)
unless policy_ok
  warn "IceCubes close-policy commit is unavailable: #{policy_error.strip}"
  exit 1
end
policy_epoch = Integer(policy_timestamp.strip, 10)

commits = post_policy_commits(integration_base, policy_epoch)
commits.each do |commit|
  next if commit.fetch("message").match?(METRIC_PATTERN)

  errors << "#{commit.fetch("sha")[0, 12]} lacks literal " \
    "'R2 <before> -> <after> / #{TOTAL_PIXELS}' metric"
end

claim_lines = ledger_available ? File.readlines(claims_path, chomp: true) : []
entries = landing_window(series_entries, ledger_landings(claim_lines))
# The one line that promotes the floor from report-only to enforcing, once its
# producer exists. See FLOOR_SERIES_WINDOW_COVERAGE for what must be true first.
check_series_coverage(
  entries, series_available,
  FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED ? errors : warnings
)

# Every recorded field the verdict LEANS ON is re-derived from the tree at that
# sha: the scored window, plus every line this candidate adds. A line is always
# newest when it is appended, so "new since the merge base" is the moment each
# one is checked, and the append-only rule above guarantees it can never change
# afterwards — which is what keeps this a constant number of `git show` calls
# rather than one per landing ever recorded.
ancestor_shas = {}
(ancestor_series || []).each { |entry| ancestor_shas[entry.fetch("sha")] = true }
verified_shas = {}
entries.each do |entry|
  verified_shas[entry.fetch("sha")] = true if entry.fetch("source") == "series"
end
series_entries.each do |entry|
  verified_shas[entry.fetch("sha")] = true unless
    ancestor_shas.key?(entry.fetch("sha"))
end
verify_landing_series(
  series_entries.select { |entry| verified_shas.key?(entry.fetch("sha")) },
  errors
)

puts "landing series #{series_window_coverage(entries)}/#{entries.length} of " \
  "the scored window from #{LANDING_SERIES_PATH} " \
  "(#{series_entries.length} landings recorded, floor " \
  "#{FLOOR_SERIES_WINDOW_COVERAGE} " \
  "#{FLOOR_SERIES_WINDOW_COVERAGE_ENFORCED ? "ENFORCED" : "report-only"}; " \
  "prose ledger #{ledger_available ? "available" : "ABSENT"})"

# The headline every close receipt and gate log now carries. A rung count and
# the one screen that already converged read as "done"; the open debt is the
# number the remaining mission is measured by, so it is stated unconditionally,
# green or red.
board_file = repo_file(R2_BOARD_PATH)
board_source = File.file?(board_file) ? File.read(board_file) : nil
open_by_screen = parse_r2_floors(board_source) if board_source
acknowledged_screens = board_source ? parse_r2_acknowledged(board_source) : []
if open_by_screen
  open_total = open_by_screen.values.sum
  # Owed is what the stall detector measures; total is what the mission is
  # measured by. Printing only one of them is how a board hides from one of the
  # two readers, so both go out, and an acknowledged screen is named as such.
  owed_total = open_by_screen
    .reject { |screen, _value| acknowledged_screens.include?(screen) }
    .values.sum
  breakdown = open_by_screen
    .sort_by { |_screen, value| -value }
    .map do |screen, value|
      acknowledged_screens.include?(screen) ? "#{screen} #{value} (acknowledged)" : "#{screen} #{value}"
    end
    .join(", ")
  open_screens = open_by_screen.count { |_screen, value| value.positive? }
  puts "R2 open #{open_total} AE across #{open_screens} " \
    "of #{open_by_screen.length} screens (#{breakdown})"
  if owed_total != open_total
    puts "R2 owed #{owed_total} AE — #{open_total - owed_total} AE acknowledged " \
      "as owing no renderer fix (#{acknowledged_screens.join(", ")})"
  end
else
  errors << "R2 board floors are unreadable at #{R2_BOARD_PATH}: the pixel " \
    "half of the north star cannot be measured"
end

# The window ends at the TIP BEING GATED, not at the last landing. Scoring only
# landed iterations made the stall unclearable by the thing that actually clears
# it: a tip that drives a floor down cannot land while the stall is active, and
# the stall cannot lift until it lands. Worse, the only satisfiable escape was a
# STALL-ACK naming a screen whose debt is still positive — so a lane that
# converged the stalled screen was pushed to certify a screen it had NOT
# decomposed, which is exactly the empty certificate §16 exists to stop.
# The tip's floors are honest by construction: `Scripts/icecubes-r2.sh` exits
# non-zero when a screen measures OVER its floor, and gate.sh propagates that,
# so a floor lowered without the pixels moving reds the same gate this check
# runs in. A decrease here is therefore measured, not asserted.
entries
  .select { |entry| entry.fetch("open").nil? }
  .each do |entry|
    errors << "the R2 board at landed #{entry.fetch("sha")[0, 12]} does not " \
      "parse, so the stall window cannot be measured against it"
  end
metrics = entries.map { |entry| entry.fetch("open") }.compact
# THE TIP MUST BE ON THE SAME SCALE AS THE WINDOW. Every landed entry is an OWED
# sum — `r2_floors_at` and `derive_landing` both drop screens the board marked
# `# ACKNOWLEDGED` — so appending the TOTAL here compared two different
# measurements: a board converged to an acknowledged-only residue read
# [0, 0, 0, 0, 0] + [2], which is a RISING window, and therefore a permanent
# stall that nothing could clear, on a board that owes nothing. It is the very
# trap the `# ACKNOWLEDGED` marker was added to remove, reintroduced one line
# below the marker's own comment. `open_total` is still what the headline prints;
# only the detector's series is owed.
metrics += [owed_total] if owed_total
stall_active = stalled?(metrics)

# The stall begins at its OLDEST landing: evidence older than that is a
# certificate from a previous frontier, not a decomposition of this one. Both
# channels carry the landing's committer epoch — the series records it, the
# ledger path resolves it while normalising the sha — so the date no longer
# needs a `git show` here, and it survives a clone that cannot resolve the sha.
stall_epoch = entries.empty? ? nil : entries.first.fetch("epoch")
stall_epoch = nil unless stall_active
last_merge_done_index = last_landing_index(claim_lines)
disposition =
  latest_disposition(claim_lines, last_merge_done_index, open_by_screen)
decomposition = nil
escalation = nil

if stall_active
  case disposition && disposition.fetch("kind")
  when "decomposition"
    decomposition = verify_decomposition(
      disposition.fetch("entry"), errors, open_by_screen, stall_epoch,
      acknowledged_screens
    )
  when "escalation"
    escalation = disposition.fetch("entry")
  else
    errors << "STALL: owed R2 AE across every screen the board has not " \
      "ACKNOWLEDGED did not decrease over " \
      "the last #{STALL_WINDOW} landed iterations " \
      "(#{metrics.last(STALL_WINDOW).join(", ")}); adding rungs does not " \
      "clear this — drive a screen floor down, or post a STALL-ACK " \
      "decomposition or STALL-ESCALATION after the latest merge"
  end
end

payload = policy_payload(
  integration_base: integration_base,
  commits: commits,
  metrics: metrics,
  stall_active: stall_active,
  decomposition: decomposition,
  errors: errors,
  open_by_screen: open_by_screen,
  escalation: escalation,
  landings: entries,
  series_landings: series_entries.length,
  series_available: series_available,
  ledger_available: ledger_available,
  warnings: warnings
)
puts "@@icecubes-close-policy #{JSON.generate(payload)}"
# On STDOUT as well as in the receipt: `gate.sh` cats this log to stderr only
# when the stage is non-zero, and a warning that only ever reached stderr on a
# green run would be a finding nothing prints and nothing keeps.
warnings.each { |warning| puts "WARNING (not enforced): #{warning}" }
errors.each { |error| warn(error) }
exit(errors.empty? ? 0 : 1)
