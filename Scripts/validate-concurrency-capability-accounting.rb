#!/usr/bin/env ruby

require "digest"
require "json"
require "set"

SUPPORTED_INVENTORY_SCHEMA = 1
SUPPORTED_STATUS_SCHEMA = 1
SUPPORTED_ACCEPTANCE_SCHEMA = 3

IMPLEMENTATION_STATUSES = %w[
  runtime-supported
  preflight-only
  diagnosed-unsupported
  excluded-compiler-abi
  deferred
  known-divergence
  unreviewed
].freeze

VERIFICATION_STATUSES = %w[
  native-parity
  focused-only
  native-red
  none
].freeze

SEMANTIC_CATALOG_ID = "project-concurrency-roadmap-v1"
SEMANTIC_CATALOG_VERSION = 1
SEMANTIC_CAPABILITY_IDS = %w[
  core-async-await-language
  task-owned-evaluation-context
  unstructured-task-runtime
  task-suspension-sleep-and-cancellation-handlers
  async-let-structured-lifetime
  task-group-core-semantics
  task-group-complete-generated-surface
  logical-mainactor-and-default-executors
  actor-declaration-safety-boundary
  actor-identity-storage-and-serial-executor
  actor-reentrancy-and-isolated-dispatch
  compiler-backed-concurrency-diagnostics
  sendable-checking
  async-sequence-stream-and-continuation-runtime
  swiftui-view-owned-async-lifecycle
  physical-parallel-execution
].freeze

def file_sha256(path)
  File.file?(path) ? Digest::SHA256.file(path).hexdigest : "unavailable"
end

def count_by(items, key)
  items.group_by { |item| item.fetch(key) }.transform_values(&:length)
end

def add_error(errors, condition, message)
  errors << message unless condition
end

inventory_path, status_path, acceptance_path, gaps_path, parity_path,
  inventory_relative, status_relative = ARGV

payload = {
  "valid" => false,
  "errors" => [],
  "inventoryPath" => inventory_relative.to_s,
  "inventoryInputPath" => inventory_path.to_s,
  "inventorySHA256" => file_sha256(inventory_path.to_s),
  "inventorySchemaVersion" => 0,
  "inventoryScopeID" => "unavailable",
  "interfaceSHA256" => "unavailable",
  "declarationCount" => 0,
  "declarationsByDomain" => {},
  "adapterRoutedDeclarationCount" => 0,
  "adapterRouteIsSupportEvidence" => false,
  "scopeComplete" => false,
  "statusPath" => status_relative.to_s,
  "statusInputPath" => status_path.to_s,
  "statusSHA256" => file_sha256(status_path.to_s),
  "statusSchemaVersion" => 0,
  "pinnedInventorySHA256" => "unavailable",
  "pinMatches" => false,
  "interfaceOverrideCount" => 0,
  "resolvedInterfaceClaimCount" => 0,
  "reviewedInterfaceClaimCount" => 0,
  "interfaceImplementationCounts" => {},
  "interfaceVerificationCounts" => {},
  "semanticCatalogID" => "unavailable",
  "semanticCatalogVersion" => 0,
  "semanticCatalogCompleteForAcceptanceScope" => false,
  "semanticCapabilityCount" => 0,
  "semanticImplementationCounts" => {},
  "semanticVerificationCounts" => {}
}

begin
  inventory = JSON.parse(File.read(inventory_path))
  status = JSON.parse(File.read(status_path))
  acceptance = JSON.parse(File.read(acceptance_path))
  open_gaps = JSON.parse(File.read(gaps_path))
  parity_cases = JSON.parse(File.read(parity_path))
  errors = payload.fetch("errors")

  inventory_schema = inventory.fetch("schemaVersion")
  status_schema = status.fetch("schemaVersion")
  acceptance_schema = acceptance.fetch("schemaVersion")
  add_error(errors, inventory_schema == SUPPORTED_INVENTORY_SCHEMA,
            "unsupported inventory schema #{inventory_schema}")
  add_error(errors, status_schema == SUPPORTED_STATUS_SCHEMA,
            "unsupported capability-status schema #{status_schema}")
  add_error(errors, acceptance_schema == SUPPORTED_ACCEPTANCE_SCHEMA,
            "unsupported acceptance schema #{acceptance_schema}")

  declarations = inventory.fetch("declarations")
  ids = declarations.map { |row| row.fetch("id") }
  add_error(errors, ids.uniq.length == ids.length,
            "duplicate generated capability IDs")
  add_error(errors, ids.all? { |id|
    id.match?(/\Aswift-concurrency-api-v1:[0-9a-f]{64}\z/)
  }, "malformed generated capability ID")
  summary = inventory.fetch("summary")
  add_error(errors, summary.fetch("declarationCount") == declarations.length,
            "inventory summary count mismatch")
  domain_counts = declarations.group_by { |row| row.fetch("domain") }
    .transform_values(&:length)
  add_error(errors, domain_counts == summary.fetch("declarationsByDomain"),
            "inventory domain summary mismatch")
  adapter_count = declarations.count { |row| row.key?("adapterIntrinsic") }
  add_error(errors,
            adapter_count == summary.fetch("adapterRoutedDeclarationCount"),
            "inventory adapter-route summary mismatch")
  scope = inventory.fetch("scope")
  add_error(errors, scope.fetch("included").is_a?(Array) &&
            !scope.fetch("included").empty?, "inventory scope has no inclusions")
  add_error(errors, scope.fetch("complete") ||
            (scope.fetch("excluded").is_a?(Array) &&
             !scope.fetch("excluded").empty?),
            "incomplete inventory scope has no exclusions")
  add_error(errors, scope.fetch("adapterRouteIsSupportEvidence") == false,
            "adapter routing must not be support evidence")

  external = acceptance.fetch("externalCapabilityAccounting")
  add_error(errors, external.fetch("inventoryPath") == inventory_relative,
            "acceptance inventory path mismatch")
  add_error(errors, external.fetch("statusPath") == status_relative,
            "acceptance status path mismatch")
  add_error(errors,
            external.fetch("inventorySchemaVersion") == inventory_schema,
            "acceptance inventory schema mismatch")
  add_error(errors, external.fetch("statusSchemaVersion") == status_schema,
            "acceptance status schema mismatch")
  add_error(errors, status.fetch("inventoryPath") == inventory_relative,
            "status inventory path mismatch")

  requirements = {}
  acceptance.fetch("milestones").each do |milestone|
    milestone.fetch("requirements").each do |requirement|
      requirements["#{milestone.fetch("id")}/#{requirement.fetch("id")}"] =
        requirement
    end
  end
  gaps = open_gaps.to_h { |gap| [gap.fetch("id"), gap] }
  parity_ids = parity_cases.map { |parity_case| parity_case.fetch("id") }.to_set

  model = status.fetch("statusModel")
  implementation_vocabulary = model.fetch("implementationStatuses")
  verification_vocabulary = model.fetch("verificationStatuses")
  add_error(errors,
            implementation_vocabulary.uniq.length ==
              implementation_vocabulary.length,
            "duplicate implementation status vocabulary")
  add_error(errors,
            verification_vocabulary.uniq.length == verification_vocabulary.length,
            "duplicate verification status vocabulary")
  add_error(errors,
            implementation_vocabulary.sort == IMPLEMENTATION_STATUSES.sort,
            "unsupported implementation status vocabulary")
  add_error(errors,
            verification_vocabulary.sort == VERIFICATION_STATUSES.sort,
            "unsupported verification status vocabulary")

  validate_claim = lambda do |claim, label|
    implementation = claim.fetch("implementationStatus")
    verification = claim.fetch("verificationStatus")
    requirement_ref = claim.fetch("requirementRef")
    evidence_cases = claim.fetch("evidenceCaseIDs")
    test_names = claim.fetch("testNames")
    gap_ids = claim.fetch("gapEvidenceIDs")
    notes = claim.fetch("notes")
    add_error(errors, IMPLEMENTATION_STATUSES.include?(implementation),
              "#{label} has unknown implementation status")
    add_error(errors, VERIFICATION_STATUSES.include?(verification),
              "#{label} has unknown verification status")
    add_error(errors, !notes.empty?, "#{label} has no rationale")
    requirement = requirements[requirement_ref]
    unless requirement
      errors << "#{label} cites unknown requirement #{requirement_ref}"
      next
    end
    declared_cases = requirement.fetch("ownedCaseIDs", []) +
      requirement.fetch("evidenceCaseIDs", [])
    add_error(errors, (evidence_cases - parity_ids.to_a).empty?,
              "#{label} cites unknown parity evidence")
    add_error(errors, (evidence_cases - declared_cases).empty?,
              "#{label} cites cases outside #{requirement_ref}")
    add_error(errors,
              (test_names - requirement.fetch("testNames", [])).empty?,
              "#{label} cites tests outside #{requirement_ref}")
    gap_ids.each do |gap_id|
      gap = gaps[gap_id]
      add_error(errors, gap && gap.fetch("requirementRef") == requirement_ref,
                "#{label} cites a gap owned by another requirement")
    end
    has_evidence = !evidence_cases.empty? || !test_names.empty?
    case implementation
    when "runtime-supported", "preflight-only"
      add_error(errors, has_evidence, "#{label} has no executable evidence")
      add_error(errors, %w[native-parity focused-only].include?(verification),
                "#{label} has incompatible positive verification")
      add_error(errors, gap_ids.empty?,
                "#{label} positive claim retains gap evidence")
    when "diagnosed-unsupported"
      add_error(errors, has_evidence && !gap_ids.empty?,
                "#{label} unsupported claim lacks evidence or gap")
      add_error(errors, %w[focused-only native-red].include?(verification),
                "#{label} unsupported claim has incompatible verification")
    when "excluded-compiler-abi"
      add_error(errors, verification == "none",
                "#{label} ABI exclusion must have no verification claim")
    when "deferred"
      add_error(errors, verification == "none",
                "#{label} deferred claim must have no verification claim")
      add_error(errors, !gap_ids.empty? || requirement.fetch("status") == "deferred",
                "#{label} deferred claim lacks gap or deferred requirement")
    when "known-divergence"
      add_error(errors, %w[none native-red].include?(verification),
                "#{label} divergence has incompatible verification")
      add_error(errors, !gap_ids.empty?, "#{label} divergence has no gap")
    when "unreviewed"
      add_error(errors, verification == "none",
                "#{label} unreviewed claim must have no verification claim")
      add_error(errors, !gap_ids.empty?, "#{label} unreviewed claim has no gap")
    end
    if verification == "native-red"
      add_error(errors, has_evidence && !gap_ids.empty?,
                "#{label} native RED lacks evidence or gap")
      add_error(errors, gap_ids.all? { |gap_id|
        gaps[gap_id]&.fetch("kind") == "native-red"
      }, "#{label} native RED cites a non-native-RED gap")
    end
  end

  overrides = status.fetch("interfaceOverrides")
  override_ids = overrides.map { |claim| claim.fetch("id") }
  add_error(errors, override_ids.uniq.length == override_ids.length,
            "duplicate capability overrides")
  add_error(errors, (override_ids - ids).empty?,
            "capability override references unknown ID")
  default_claim = status.fetch("defaultInterfaceClaim")
  add_error(errors,
            default_claim.fetch("implementationStatus") == "unreviewed" &&
              default_claim.fetch("verificationStatus") == "none",
            "default interface claim must be unreviewed/none")
  validate_claim.call(default_claim, "default interface claim")
  overrides.each do |claim|
    validate_claim.call(claim, "interface override #{claim.fetch("id")}")
  end
  overrides_by_id = overrides.to_h { |claim| [claim.fetch("id"), claim] }
  resolved = ids.map { |id| overrides_by_id.fetch(id, default_claim) }

  semantic = status.fetch("semanticCapabilities")
  semantic_ids = semantic.map { |claim| claim.fetch("id") }
  add_error(errors, semantic_ids.uniq.length == semantic_ids.length,
            "duplicate semantic capability IDs")
  catalog = status.fetch("semanticCatalog")
  add_error(errors, catalog.fetch("id") == SEMANTIC_CATALOG_ID,
            "unsupported semantic catalog ID")
  add_error(errors, catalog.fetch("version") == SEMANTIC_CATALOG_VERSION,
            "unsupported semantic catalog version")
  add_error(errors, catalog.fetch("capabilityIDs") == SEMANTIC_CAPABILITY_IDS,
            "semantic catalog content mismatch")
  add_error(errors, semantic_ids == catalog.fetch("capabilityIDs"),
            "semantic claims do not exactly cover their catalog")
  semantic.each do |claim|
    validate_claim.call(claim, "semantic capability #{claim.fetch("id")}")
  end

  payload["inventorySchemaVersion"] = inventory_schema
  payload["inventoryScopeID"] = scope.fetch("id")
  payload["interfaceSHA256"] = inventory.fetch("source")
    .fetch("interfaceSHA256")
  payload["declarationCount"] = declarations.length
  payload["declarationsByDomain"] = domain_counts
  payload["adapterRoutedDeclarationCount"] = adapter_count
  payload["adapterRouteIsSupportEvidence"] =
    scope.fetch("adapterRouteIsSupportEvidence")
  payload["scopeComplete"] = scope.fetch("complete")
  payload["statusSchemaVersion"] = status_schema
  payload["pinnedInventorySHA256"] = status.fetch("inventorySHA256")
  payload["pinMatches"] = payload["inventorySHA256"] ==
    payload["pinnedInventorySHA256"]
  add_error(errors, payload["pinMatches"],
            "capability status inventory pin mismatch")
  payload["interfaceOverrideCount"] = overrides.length
  payload["resolvedInterfaceClaimCount"] = resolved.length
  payload["interfaceImplementationCounts"] = count_by(
    resolved, "implementationStatus")
  payload["interfaceVerificationCounts"] = count_by(
    resolved, "verificationStatus")
  payload["reviewedInterfaceClaimCount"] = declarations.length -
    payload["interfaceImplementationCounts"].fetch("unreviewed", 0)
  payload["semanticCatalogID"] = catalog.fetch("id")
  payload["semanticCatalogVersion"] = catalog.fetch("version")
  payload["semanticCatalogCompleteForAcceptanceScope"] =
    catalog.fetch("completeForAcceptanceScope")
  payload["semanticCapabilityCount"] = semantic.length
  payload["semanticImplementationCounts"] = count_by(
    semantic, "implementationStatus")
  payload["semanticVerificationCounts"] = count_by(
    semantic, "verificationStatus")

  if requirements.fetch("M7/generated-signatures-and-preflight")
      .fetch("status") == "covered"
    add_error(errors,
              payload["interfaceImplementationCounts"].fetch("unreviewed", 0)
                .zero?,
              "M7 is covered while generated declarations remain unreviewed")
  end
  if requirements.fetch("M4/remaining-task-group-surface")
      .fetch("status") == "covered"
    task_group_ids = declarations.filter_map do |row|
      row.fetch("id") if row.fetch("domain") == "task-group-member"
    end
    unreviewed_group_ids = task_group_ids.select do |id|
      overrides_by_id.fetch(id, default_claim)
        .fetch("implementationStatus") == "unreviewed"
    end
    add_error(errors, unreviewed_group_ids.empty?,
              "M4 group surface is covered while group rows remain unreviewed")
  end
rescue StandardError => error
  payload.fetch("errors") << "#{error.class}: #{error.message}"
end

payload["valid"] = payload.fetch("errors").empty?
puts JSON.generate(payload)
exit(payload["valid"] ? 0 : 1)
