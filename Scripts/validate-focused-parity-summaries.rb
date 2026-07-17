#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

PREFIX = "@@concurrency-parity-summary "

unless ARGV.length >= 3
  warn "usage: #{$PROGRAM_NAME} MANIFEST CASE_ID WORKER_LOG..."
  exit 2
end

manifest_path, case_id, *log_paths = ARGV
begin
  manifest = JSON.parse(File.read(manifest_path))
rescue StandardError => error
  warn "could not read concurrency parity manifest: #{error}"
  exit 2
end

runtime_cases = manifest.select { |entry| entry.fetch("mode") == "runtime" }
matches = runtime_cases.each_index.select do |index|
  runtime_cases.fetch(index).fetch("id") == case_id
end
if matches.length != 1
  warn "focused parity case #{case_id.inspect} must identify one runtime case"
  exit 2
end

case_index = matches.first
assertion = runtime_cases.fetch(case_index).fetch("assertion")
expected_repetitions = [
  Integer(runtime_cases.fetch(case_index).fetch("repetitions", 1)), 1
].max
errors = []
completed_repetitions = 0
worker_receipts = []

log_paths.each_with_index do |path, worker_index|
  begin
    markers = File.readlines(path, chomp: true).map do |line|
      stripped = line.strip
      stripped.delete_prefix(PREFIX) if stripped.start_with?(PREFIX)
    end.compact
  rescue StandardError => error
    errors << "worker #{worker_index}: could not read #{path}: #{error}"
    next
  end

  if markers.length != 1
    errors << "worker #{worker_index}: expected one summary marker, found #{markers.length}"
    next
  end

  begin
    summary = JSON.parse(markers.first)
  rescue JSON::ParserError => error
    errors << "worker #{worker_index}: malformed summary JSON: #{error.message}"
    next
  end

  selected_repetitions = summary["selectedRepetitionsByCase"]
  completed = summary["completedRepetitionsByCase"]
  digests = summary["nativeObservationSHA256ByCase"]
  repetition_count = selected_repetitions.is_a?(Hash) &&
    selected_repetitions[case_id]

  errors << "worker #{worker_index}: unsupported summary version" unless summary["version"] == 1
  unless summary["shardIndex"] == case_index &&
         summary["shardCount"] == runtime_cases.length
    errors << "worker #{worker_index}: receipt does not select the manifest case shard"
  end
  unless summary["selectedCount"] == 1 &&
         summary["completedCount"] == 1 &&
         summary["selectedIDs"] == [case_id] &&
         summary["completedIDs"] == [case_id]
    errors << "worker #{worker_index}: selected/completed IDs must equal #{[case_id].inspect}"
  end
  unless repetition_count.is_a?(Integer) && repetition_count.positive? &&
         repetition_count <= expected_repetitions
    errors << "worker #{worker_index}: invalid selected repetition count"
    next
  end
  unless completed == { case_id => repetition_count }
    errors << "worker #{worker_index}: completed repetitions do not equal selected repetitions"
  end
  unless digests.is_a?(Hash) && digests.keys == [case_id] &&
         digests.fetch(case_id, "").match?(/\A[0-9a-f]{64}\z/)
    errors << "worker #{worker_index}: missing lowercase native-observation SHA-256"
  end

  completed_repetitions += repetition_count
  worker_receipts << {
    workerIndex: worker_index,
    repetitions: repetition_count,
    nativeObservationSHA256: digests.is_a?(Hash) ? digests[case_id] : nil
  }
end

unless completed_repetitions == expected_repetitions
  errors << "completed #{completed_repetitions}/#{expected_repetitions} repetitions"
end
worker_repetition_counts = worker_receipts.map { |receipt| receipt.fetch(:repetitions) }
unless worker_repetition_counts.uniq.length == 1
  errors << "workers must own equal repetition counts"
end
if assertion == "exact"
  worker_digests = worker_receipts.map do |receipt|
    receipt.fetch(:nativeObservationSHA256)
  end
  unless worker_digests.uniq.length == 1
    errors << "exact-case native observation digests differ between workers"
  end
end

unless errors.empty?
  errors.each { |error| warn "focused parity validation: #{error}" }
  exit 1
end

puts "@@focused-parity-summary " + JSON.generate(
  version: 1,
  status: "passed",
  caseID: case_id,
  workerCount: log_paths.length,
  completedRepetitions: completed_repetitions,
  expectedRepetitions: expected_repetitions,
  workers: worker_receipts
)
