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
LANDED_METRIC_PATTERN =
  /\bR2\b[^\n]*?(\d+)\s*\/\s*#{TOTAL_PIXELS}\b/
DECOMPOSITION_PATTERN =
  /\bSTALL-ACK\b[^\n]*?\boverlay-cross-import@([0-9a-f]{8,40})\b[^\n]*?\brow AE\s+(\d+)\s*->\s*0\b/i
ROW_MICROTWIN_PATH =
  "Tests/SwiftUIBridgeTests/IceCubesMicroTwinTests.swift"
ROW_MICROTWIN_NAME = "translatedRowPreservesNativePixels"

def git(*arguments)
  stdout, stderr, status = Open3.capture3("git", *arguments)
  [stdout, stderr, status.success?]
end

def landed_metrics(lines)
  lines.each_with_object([]) do |line, metrics|
    next unless line.include?("MERGE-DONE")

    match = line.match(LANDED_METRIC_PATTERN)
    metrics << Integer(match[1], 10) if match
  end
end

def stalled?(metrics)
  window = metrics.last(STALL_WINDOW)
  window.length == STALL_WINDOW &&
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
      "commit" => match[1],
      "redAE" => Integer(match[2], 10)
    }
  end.last
end

def verify_decomposition(acknowledgement, errors)
  remote_tip, remote_error, remote_ok = git(
    "rev-parse", "refs/remotes/origin/overlay-cross-import"
  )
  unless remote_ok
    errors << "overlay-cross-import is not available as a pushed remote ref: " \
      "#{remote_error.strip}"
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

  _, ancestry_error, ancestry_ok = git(
    "merge-base", "--is-ancestor", evidence_sha.strip, remote_tip.strip
  )
  unless ancestry_ok
    errors << "STALL-ACK decomposition commit is not retained by " \
      "origin/overlay-cross-import: #{ancestry_error.strip}"
  end

  source, source_error, source_ok = git(
    "show", "#{evidence_sha.strip}:#{ROW_MICROTWIN_PATH}"
  )
  unless source_ok && source.include?(ROW_MICROTWIN_NAME)
    errors << "STALL-ACK decomposition commit does not contain " \
      "#{ROW_MICROTWIN_PATH}:#{ROW_MICROTWIN_NAME}: #{source_error.strip}"
  end

  {
    "commit" => evidence_sha.strip,
    "remoteTip" => remote_tip.strip,
    "redAE" => acknowledgement.fetch("redAE"),
    "greenAE" => 0,
    "microtwin" => ROW_MICROTWIN_NAME
  }
end

def policy_payload(
  integration_base:, commits:, metrics:, stall_active:, decomposition:, errors:
)
  payload = {
    "version" => 1,
    "status" => errors.empty? ? "passed" : "failed",
    "integrationBase" => integration_base,
    "policyCommit" => POLICY_COMMIT,
    "checkedCommits" => commits.map { |commit| commit.fetch("sha") },
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
  sample = [
    "t lane MERGE-DONE x R2 exact 60000/630000",
    "t lane MERGE-DONE x R2 exact 59000/630000",
    "t lane MERGE-DONE x R2 exact 59000/630000",
    "t lane MERGE-DONE x R2 exact 59000/630000",
    "t lane MERGE-DONE x R2 exact 59000/630000",
    "t lane MERGE-DONE x R2 exact 59000/630000"
  ]
  raise "landed metric parsing failed" unless landed_metrics(sample) ==
    [60_000, 59_000, 59_000, 59_000, 59_000, 59_000]
  raise "equal tail should stall" unless stalled?(landed_metrics(sample))
  raise "decreasing tail must not stall" if stalled?(
    [60_000, 60_000, 59_000, 59_000, 58_000])
  raise "literal metric accepted incorrectly" unless
    "Metric delta: R2 59695 -> 59695 / 630000".match?(METRIC_PATTERN)
  raise "nonliteral metric accepted" if
    "Metric delta: R2 AE 59695 -> 59695 / 630000".match?(METRIC_PATTERN)

  acknowledgement = decomposition_acknowledgement(
    [
      "t lane MERGE-DONE x R2 exact 59695/630000",
      "t lane STALL-ACK decomposition overlay-cross-import@abcdef12 " \
        "row AE 1228 -> 0"
    ],
    0
  )
  raise "decomposition acknowledgement parsing failed" unless
    acknowledgement == {
      "line" => "t lane STALL-ACK decomposition " \
        "overlay-cross-import@abcdef12 row AE 1228 -> 0",
      "commit" => "abcdef12",
      "redAE" => 1228
    }

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
  assert_plist_representable(unstalled_payload)

  decomposition = {
    "commit" => "abcdef12",
    "remoteTip" => "abcdef123456",
    "redAE" => 1228,
    "greenAE" => 0,
    "microtwin" => ROW_MICROTWIN_NAME
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
metrics = landed_metrics(claim_lines)
stall_active = stalled?(metrics)
last_merge_done_index =
  claim_lines.rindex { |line| line.include?("MERGE-DONE") } || -1
acknowledgement =
  decomposition_acknowledgement(claim_lines, last_merge_done_index)
decomposition = nil

if stall_active
  if acknowledgement
    decomposition = verify_decomposition(acknowledgement, errors)
  elsif claim_lines.drop(last_merge_done_index + 1).none? do |line|
      line.match?(/\bSTALL-ESCALATION\b/i)
    end
    errors << "STALL: the last #{STALL_WINDOW} landed R2 values did not " \
      "decrease (#{metrics.last(STALL_WINDOW).join(", ")}); post a " \
      "STALL-ACK decomposition or STALL-ESCALATION after the latest merge"
  end
end

payload = policy_payload(
  integration_base: integration_base,
  commits: commits,
  metrics: metrics,
  stall_active: stall_active,
  decomposition: decomposition,
  errors: errors
)
puts "@@icecubes-close-policy #{JSON.generate(payload)}"
errors.each { |error| warn(error) }
exit(errors.empty? ? 0 : 1)
