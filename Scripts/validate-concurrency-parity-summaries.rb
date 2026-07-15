#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

PREFIX = "@@concurrency-parity-summary "

unless ARGV.length >= 2
  warn "usage: #{$PROGRAM_NAME} MANIFEST SHARD_LOG..."
  exit 2
end

manifest_path, *log_paths = ARGV
begin
  manifest = JSON.parse(File.read(manifest_path))
rescue StandardError => error
  warn "could not read concurrency parity manifest: #{error}"
  exit 2
end

expected_ids = manifest.each_with_object([]) do |entry, ids|
  ids << entry.fetch("id") if entry.fetch("mode") == "runtime"
end
expected_repetitions = manifest.each_with_object({}) do |entry, repetitions|
  next unless entry.fetch("mode") == "runtime"
  repetitions[entry.fetch("id")] = [Integer(entry.fetch("repetitions", 1)), 1].max
end
errors = []
if expected_ids.uniq.length != expected_ids.length
  errors << "runtime manifest contains duplicate IDs"
end

selected_owner = {}
selected_union = []
shard_receipts = []
native_observation_digests = {}
completed_repetitions = {}
log_paths.each_with_index do |path, expected_index|
  begin
    markers = File.readlines(path, chomp: true).map do |line|
      stripped = line.strip
      stripped.delete_prefix(PREFIX) if stripped.start_with?(PREFIX)
    end.compact
  rescue StandardError => error
    errors << "shard #{expected_index}: could not read #{path}: #{error}"
    next
  end

  if markers.length != 1
    errors << "shard #{expected_index}: expected exactly one summary marker, found #{markers.length}"
    next
  end

  begin
    summary = JSON.parse(markers.first)
  rescue JSON::ParserError => error
    errors << "shard #{expected_index}: malformed summary JSON: #{error.message}"
    next
  end

  unless summary["version"] == 1
    errors << "shard #{expected_index}: unsupported summary version #{summary["version"].inspect}"
  end
  unless summary["shardIndex"] == expected_index
    errors << "shard #{expected_index}: receipt claims index #{summary["shardIndex"].inspect}"
  end
  unless summary["shardCount"] == log_paths.length
    errors << "shard #{expected_index}: receipt claims count #{summary["shardCount"].inspect}, expected #{log_paths.length}"
  end

  selected = summary["selectedIDs"]
  completed = summary["completedIDs"]
  selected_repetitions = summary["selectedRepetitionsByCase"]
  completed_case_repetitions = summary["completedRepetitionsByCase"]
  digests = summary["nativeObservationSHA256ByCase"]
  unless selected.is_a?(Array) && selected.all? { |id| id.is_a?(String) }
    errors << "shard #{expected_index}: selectedIDs must be an array of strings"
    next
  end
  unless completed.is_a?(Array) && completed.all? { |id| id.is_a?(String) }
    errors << "shard #{expected_index}: completedIDs must be an array of strings"
    next
  end
  unless digests.is_a?(Hash) && digests.keys.all? { |id| id.is_a?(String) } &&
         digests.values.all? { |digest| digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/) }
    errors << "shard #{expected_index}: native observation digests must be lowercase SHA-256 values"
    next
  end
  unless selected_repetitions.is_a?(Hash) &&
         selected_repetitions.values.all? { |count| count.is_a?(Integer) && count.positive? }
    errors << "shard #{expected_index}: selected repetition counts must be positive integers"
    next
  end
  unless completed_case_repetitions.is_a?(Hash) &&
         completed_case_repetitions.values.all? { |count| count.is_a?(Integer) && count.positive? }
    errors << "shard #{expected_index}: completed repetition counts must be positive integers"
    next
  end
  unless summary["selectedCount"].is_a?(Integer)
    errors << "shard #{expected_index}: selectedCount must be an integer"
  end
  unless summary["completedCount"].is_a?(Integer)
    errors << "shard #{expected_index}: completedCount must be an integer"
  end
  if summary["selectedCount"] != selected.length
    errors << "shard #{expected_index}: selectedCount does not match selectedIDs"
  end
  if summary["completedCount"] != completed.length
    errors << "shard #{expected_index}: completedCount does not match completedIDs"
  end
  if selected.uniq.length != selected.length
    errors << "shard #{expected_index}: selectedIDs contains duplicates"
  end
  if completed.uniq.length != completed.length
    errors << "shard #{expected_index}: completedIDs contains duplicates"
  end
  unless completed == selected
    missing = selected - completed
    unexpected = completed - selected
    errors << "shard #{expected_index}: completedIDs != selectedIDs (missing=#{missing.inspect}, unexpected=#{unexpected.inspect})"
  end
  unless digests.keys.sort == completed.sort
    errors << "shard #{expected_index}: native observation digest IDs do not equal completedIDs"
  end
  expected_selected_repetitions = selected.to_h do |id|
    [id, expected_repetitions[id]]
  end
  unless selected_repetitions == expected_selected_repetitions
    errors << "shard #{expected_index}: selected repetition counts do not match the manifest"
  end
  unless completed_case_repetitions == selected_repetitions
    errors << "shard #{expected_index}: completed repetition counts do not equal selected counts"
  end

  selected.each do |id|
    if selected_owner.key?(id)
      errors << "runtime ID #{id.inspect} selected by shards #{selected_owner[id]} and #{expected_index}"
    else
      selected_owner[id] = expected_index
    end
    selected_union << id
    native_observation_digests[id] = digests[id] if digests.key?(id)
    completed_repetitions[id] = completed_case_repetitions[id]
  end
  shard_receipts << {
    shardIndex: expected_index,
    selectedIDs: selected,
    completedIDs: completed,
    selectedRepetitionsByCase: selected_repetitions,
    completedRepetitionsByCase: completed_case_repetitions,
    nativeObservationSHA256ByCase: digests
  }
end

unless selected_union.sort == expected_ids.sort
  errors << "selected shard union does not equal runtime manifest IDs " \
            "(missing=#{expected_ids - selected_union}, unexpected=#{selected_union - expected_ids})"
end

unless errors.empty?
  errors.each { |error| warn "concurrency parity shard validation: #{error}" }
  exit 1
end

runtime_entries = manifest.select { |entry| entry.fetch("mode") == "runtime" }
runtime_repetitions = runtime_entries.sum do |entry|
  [Integer(entry.fetch("repetitions", 1)), 1].max
end
puts "@@concurrency-parity-gate-summary " + JSON.generate(
  version: 1,
  status: "passed",
  shardCount: log_paths.length,
  runtimeCaseCount: expected_ids.length,
  runtimeRepetitionCount: runtime_repetitions,
  selectedIDs: expected_ids,
  completedIDs: expected_ids,
  selectedRepetitionsByCase: expected_repetitions,
  completedRepetitionsByCase: expected_ids.to_h do |id|
    [id, completed_repetitions.fetch(id)]
  end,
  nativeObservationSHA256ByCase: expected_ids.to_h do |id|
    [id, native_observation_digests.fetch(id)]
  end,
  shards: shard_receipts.sort_by { |receipt| receipt.fetch(:shardIndex) }
)
