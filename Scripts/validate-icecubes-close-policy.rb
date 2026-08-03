#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

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
R2_FLOORS_PATTERN = /R2_FLOORS=\(\s*(.*?)\s*\)/m
R2_FLOOR_ENTRY_PATTERN = /^\s*([A-Za-z][\w-]*)\s+(\d+)\s*$/
# Four MERGE-DONE spellings are in the ledger (`MERGE-DONE <sha>`,
# `MERGE-DONE <lane> <sha>`, a steward form, and 7-hex shorthand), so the sha is
# found by candidate rather than by position. `git show` is the arbiter: a
# candidate that does not resolve to the board is simply not a sha.
MERGE_DONE_SHA_PATTERN = /\b[0-9a-f]{7,40}\b/
MERGE_DONE_SHA_CANDIDATES = 4

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

  entries = body.scan(R2_FLOOR_ENTRY_PATTERN)
  return nil if entries.empty?

  entries.to_h { |screen, value| [screen, Integer(value, 10)] }
end

def r2_floors_at(sha)
  source, _error, ok = git("show", "#{sha}:#{R2_BOARD_PATH}")
  return nil unless ok

  parse_r2_floors(source)
end

# Walks back from the newest claim, so only the window's worth of shas is
# resolved instead of every MERGE-DONE ever posted. Returns the landing sha
# beside its open debt — the oldest sha in the window dates the stall.
def landed_entries(lines, resolver: method(:r2_floors_at), limit: STALL_WINDOW)
  entries = []
  lines.reverse_each do |line|
    break if entries.length == limit

    marker = line.index("MERGE-DONE")
    next unless marker

    landed = nil
    # /usr/bin/ruby is 2.6 (no filter_map) and the gate calls it by path.
    line[marker..-1]
      .scan(MERGE_DONE_SHA_PATTERN)
      .first(MERGE_DONE_SHA_CANDIDATES)
      .each do |candidate|
        floors = resolver.call(candidate)
        next unless floors

        landed = { "sha" => candidate, "open" => floors.values.sum }
        break
      end
    next unless landed

    entries << landed
  end
  entries.reverse
end

def landed_metrics(lines, resolver: method(:r2_floors_at), limit: STALL_WINDOW)
  landed_entries(lines, resolver: resolver, limit: limit)
    .map { |entry| entry.fetch("open") }
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
  lines.drop(last_merge_done_index + 1).each_with_object([]) do |line, matches|
    match = line.match(DECOMPOSITION_PATTERN)
    next unless match

    matches << {
      "line" => line.strip,
      "screen" => match[1],
      "branch" => match[2],
      "commit" => match[3],
      "microtwin" => match[4],
      "redAE" => Integer(match[5], 10)
    }
  end.last
end

def verify_decomposition(acknowledgement, errors, open_by_screen, stall_epoch)
  screen = acknowledgement.fetch("screen")
  branch = acknowledgement.fetch("branch")
  microtwin = acknowledgement.fetch("microtwin")

  # The ack must answer debt the board still measures — decomposing a screen
  # that already reads AE 0 discharges nothing.
  if open_by_screen
    if !open_by_screen.key?(screen)
      errors << "STALL-ACK names screen '#{screen}', which the R2 board does " \
        "not measure (#{open_by_screen.keys.join(", ")})"
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
  open_by_screen: nil
)
  payload = {
    "version" => 2,
    "status" => errors.empty? ? "passed" : "failed",
    "integrationBase" => integration_base,
    "policyCommit" => POLICY_COMMIT,
    "checkedCommits" => commits.map { |commit| commit.fetch("sha") },
    "landedR2Metric" => "open-ae-sum-all-screens",
    "landedR2Tail" => metrics.last(STALL_WINDOW),
    "stallWindow" => STALL_WINDOW,
    "stallActive" => stall_active,
    "stallDisposition" =>
      if !stall_active
        "not-stalled"
      elsif decomposition
        "decomposition"
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

unless ARGV.length.between?(1, 2)
  warn "usage: #{$PROGRAM_NAME} CLAIMS_PATH [INTEGRATION_BASE]"
  exit 2
end

claims_path = ARGV.fetch(0)
integration_base = ARGV.fetch(1, "origin/main")
errors = []

unless File.file?(claims_path)
  warn "IceCubes claims ledger is unavailable: #{claims_path}"
  exit 1
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

claim_lines = File.readlines(claims_path, chomp: true)
entries = landed_entries(claim_lines)
metrics = entries.map { |entry| entry.fetch("open") }
stall_active = stalled?(metrics)

# The stall begins at its OLDEST landing: evidence older than that is a
# certificate from a previous frontier, not a decomposition of this one.
stall_epoch = nil
if stall_active && !entries.empty?
  window_stamp, _window_error, window_ok = git(
    "show", "-s", "--format=%ct", entries.first.fetch("sha")
  )
  stall_epoch = Integer(window_stamp.strip, 10) if window_ok
end

# The headline every close receipt and gate log now carries. A rung count and
# the one screen that already converged read as "done"; the open debt is the
# number the remaining mission is measured by, so it is stated unconditionally,
# green or red.
open_by_screen = parse_r2_floors(File.read(R2_BOARD_PATH)) if
  File.file?(R2_BOARD_PATH)
if open_by_screen
  open_total = open_by_screen.values.sum
  breakdown = open_by_screen
    .sort_by { |_screen, value| -value }
    .map { |screen, value| "#{screen} #{value}" }
    .join(", ")
  open_screens = open_by_screen.count { |_screen, value| value.positive? }
  puts "R2 open #{open_total} AE across #{open_screens} " \
    "of #{open_by_screen.length} screens (#{breakdown})"
else
  errors << "R2 board floors are unreadable at #{R2_BOARD_PATH}: the pixel " \
    "half of the north star cannot be measured"
end
last_merge_done_index =
  claim_lines.rindex { |line| line.include?("MERGE-DONE") } || -1
acknowledgement =
  decomposition_acknowledgement(claim_lines, last_merge_done_index)
decomposition = nil

if stall_active
  if acknowledgement
    decomposition = verify_decomposition(
      acknowledgement, errors, open_by_screen, stall_epoch
    )
  elsif claim_lines.drop(last_merge_done_index + 1).none? do |line|
      line.match?(/\bSTALL-ESCALATION\b/i)
    end
    errors << "STALL: open R2 AE across ALL screens did not decrease over " \
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
  open_by_screen: open_by_screen
)
puts "@@icecubes-close-policy #{JSON.generate(payload)}"
errors.each { |error| warn(error) }
exit(errors.empty? ? 0 : 1)
