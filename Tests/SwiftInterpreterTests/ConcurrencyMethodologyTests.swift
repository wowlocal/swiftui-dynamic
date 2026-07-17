import CryptoKit
import Foundation
import Testing

private enum AcceptanceMilestoneStatus: String, Decodable {
    case complete
    case provisional
    case partial
    case notStarted = "not-started"
    case deferred
}

private enum AcceptanceRequirementStatus: String, Decodable {
    case covered
    case open
    case deferred
}

private enum AcceptanceOwner: String, Decodable {
    case verification
    case runtime
    case compiler
    case generator
    case integration
}

private enum AcceptanceCoverage: String, Decodable {
    case success
    case failure
    case cancellation
    case cleanup
    case diagnostic
    case lifetime
    case ownership
    case inheritance
    case liveness
    case stress
    case surface
    case isolation
    case executor
    case terminalState = "terminal-state"
    case sharding
    case negativeControl = "negative-control"
    case audit
}

private enum AcceptanceGapKind: String, Decodable {
    case nativeRed = "native-red"
    case verificationGap = "verification-gap"
    case coverageGap = "coverage-gap"
    case surfaceGap = "surface-gap"
}

private struct AcceptanceMatrix: Decodable {
    let schemaVersion: Int
    let externalCapabilityAccounting: ExternalCapabilityAccounting
    let executionPlan: AcceptanceExecutionPlan
    let milestones: [AcceptanceMilestone]
}

private struct ExternalCapabilityAccounting: Decodable {
    let inventoryPath: String
    let statusPath: String
    let inventorySchemaVersion: Int
    let statusSchemaVersion: Int
    let ownerRequirementRef: String
}

private struct AcceptanceExecutionPlan: Decodable {
    let currentTail: AcceptanceCurrentTail
    let nextMajorCycle: AcceptanceNextMajorCycle
}

private struct AcceptanceCurrentTail: Decodable {
    let id: String
    let state: String
    let milestoneIDs: [String]
    let requirementRefs: [String]
}

private struct AcceptanceNextMajorCycle: Decodable {
    let id: String
    let state: String
    let milestoneID: String
    let entryRequirementRefs: [String]
}

private struct AcceptanceMilestone: Decodable {
    let id: String
    let title: String
    let status: AcceptanceMilestoneStatus
    let dependsOn: [String]
    let ledgerEvidence: String
    let ledgerRemainingWork: String
    let requirements: [AcceptanceRequirement]
}

private struct AcceptanceRequirement: Decodable {
    let id: String
    let status: AcceptanceRequirementStatus
    let owners: [AcceptanceOwner]
    let coverage: [AcceptanceCoverage]
    let dependsOnRequirements: [String]
    let ownedCaseIDs: [String]
    let evidenceCaseIDs: [String]
    let testNames: [String]
    let evidenceByCoverage: [String: [String]]
    let gapEvidenceIDs: [String]
    let notes: String

    private enum CodingKeys: String, CodingKey {
        case id, status, owners, coverage, dependsOnRequirements
        case ownedCaseIDs, evidenceCaseIDs, testNames, evidenceByCoverage
        case gapEvidenceIDs, notes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(
            AcceptanceRequirementStatus.self, forKey: .status,
        )
        owners = try values.decode([AcceptanceOwner].self, forKey: .owners)
        coverage = try values.decode([AcceptanceCoverage].self, forKey: .coverage)
        dependsOnRequirements = try values.decodeIfPresent(
            [String].self, forKey: .dependsOnRequirements,
        ) ?? []
        ownedCaseIDs = try values.decodeIfPresent(
            [String].self, forKey: .ownedCaseIDs,
        ) ?? []
        evidenceCaseIDs = try values.decodeIfPresent(
            [String].self, forKey: .evidenceCaseIDs,
        ) ?? []
        testNames = try values.decodeIfPresent(
            [String].self, forKey: .testNames,
        ) ?? []
        evidenceByCoverage = try values.decodeIfPresent(
            [String: [String]].self, forKey: .evidenceByCoverage,
        ) ?? [:]
        gapEvidenceIDs = try values.decodeIfPresent(
            [String].self, forKey: .gapEvidenceIDs,
        ) ?? []
        notes = try values.decode(String.self, forKey: .notes)
    }
}

private struct AcceptanceParityCase: Decodable {
    let id: String
    let mode: String
    let repetitions: Int
}

private struct AcceptanceOpenGap: Decodable {
    let id: String
    let requirementRef: String
    let kind: AcceptanceGapKind
    let expectedObservation: String
    let currentObservation: String
    let reproductionTest: String?
    let parityCase: AcceptanceOpenGapParityCase?
}

private struct AcceptanceOpenGapParityCase: Decodable {
    let id: String
    let fixture: String
}

private struct AcceptanceLedgerRow {
    let status: String
    let evidence: String
    let remainingWork: String
}

private enum CapabilityImplementationStatus: String, CaseIterable, Decodable {
    case runtimeSupported = "runtime-supported"
    case preflightOnly = "preflight-only"
    case diagnosedUnsupported = "diagnosed-unsupported"
    case excludedCompilerABI = "excluded-compiler-abi"
    case deferred
    case knownDivergence = "known-divergence"
    case unreviewed
}

private enum CapabilityVerificationStatus: String, CaseIterable, Decodable {
    case nativeParity = "native-parity"
    case focusedOnly = "focused-only"
    case nativeRed = "native-red"
    case none
}

private struct CapabilityInventoryDocument: Decodable {
    let schemaVersion: Int
    let scope: CapabilityInventoryScope
    let summary: CapabilityInventorySummary
    let declarations: [CapabilityInventoryDeclaration]
}

private struct CapabilityInventoryScope: Decodable {
    let id: String
    let complete: Bool
    let excluded: [String]
    let adapterRouteIsSupportEvidence: Bool
}

private struct CapabilityInventorySummary: Decodable {
    let declarationCount: Int
    let adapterRoutedDeclarationCount: Int
    let declarationsByDomain: [String: Int]
}

private struct CapabilityInventoryDeclaration: Decodable {
    let id: String
    let domain: String
    let container: String?
    let name: String
    let declaration: String
    let adapterIntrinsic: String?
}

private struct CapabilityStatusDocument: Decodable {
    let schemaVersion: Int
    let inventoryPath: String
    let inventorySHA256: String
    let statusModel: CapabilityStatusModel
    let semanticCatalog: CapabilitySemanticCatalog
    let defaultInterfaceClaim: CapabilityClaim
    let interfaceOverrides: [CapabilityInterfaceOverride]
    let semanticCapabilities: [CapabilitySemanticClaim]
}

private struct CapabilitySemanticCatalog: Decodable {
    let id: String
    let version: Int
    let completeForAcceptanceScope: Bool
    let scope: String
    let excluded: [String]
    let capabilityIDs: [String]
}

private struct CapabilityStatusModel: Decodable {
    let implementationStatuses: [String]
    let verificationStatuses: [String]
    let rule: String
}

private struct CapabilityClaim: Decodable {
    let implementationStatus: CapabilityImplementationStatus
    let verificationStatus: CapabilityVerificationStatus
    let requirementRef: String
    let evidenceCaseIDs: [String]
    let testNames: [String]
    let gapEvidenceIDs: [String]
    let notes: String
}

private struct CapabilityInterfaceOverride: Decodable {
    let id: String
    let implementationStatus: CapabilityImplementationStatus
    let verificationStatus: CapabilityVerificationStatus
    let requirementRef: String
    let evidenceCaseIDs: [String]
    let testNames: [String]
    let gapEvidenceIDs: [String]
    let notes: String

    var claim: CapabilityClaim {
        CapabilityClaim(
            implementationStatus: implementationStatus,
            verificationStatus: verificationStatus,
            requirementRef: requirementRef,
            evidenceCaseIDs: evidenceCaseIDs,
            testNames: testNames,
            gapEvidenceIDs: gapEvidenceIDs,
            notes: notes,
        )
    }
}

private struct CapabilitySemanticClaim: Decodable {
    let id: String
    let implementationStatus: CapabilityImplementationStatus
    let verificationStatus: CapabilityVerificationStatus
    let requirementRef: String
    let evidenceCaseIDs: [String]
    let testNames: [String]
    let gapEvidenceIDs: [String]
    let notes: String

    var claim: CapabilityClaim {
        CapabilityClaim(
            implementationStatus: implementationStatus,
            verificationStatus: verificationStatus,
            requirementRef: requirementRef,
            evidenceCaseIDs: evidenceCaseIDs,
            testNames: testNames,
            gapEvidenceIDs: gapEvidenceIDs,
            notes: notes,
        )
    }
}

private struct ValidatorProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

@Suite("Concurrency methodology")
struct ConcurrencyMethodologyTests {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test func milestoneAcceptanceMatrixIsCompleteAndConsistent() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true,
        )
        let matrix = try JSONDecoder().decode(
            AcceptanceMatrix.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "milestone-acceptance.json")),
        )
        let parityCases = try JSONDecoder().decode(
            [AcceptanceParityCase].self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "parity-cases.json")),
        )
        let openGaps = try JSONDecoder().decode(
            [AcceptanceOpenGap].self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "open-gaps.json")),
        )
        let ledgerRows = try loadLedgerRows()
        let testFunctionNames = try loadTestFunctionNames()

        #expect(matrix.schemaVersion == 3)
        #expect(matrix.milestones.map(\.id) == (0 ... 9).map { "M\($0)" })

        let milestoneIDs = Set(matrix.milestones.map(\.id))
        #expect(milestoneIDs.count == matrix.milestones.count)
        let parityCaseIDs = Set(parityCases.map(\.id))
        #expect(parityCaseIDs.count == parityCases.count)
        let requirementRefs = Set(matrix.milestones.flatMap { milestone in
            milestone.requirements.map { "\(milestone.id)/\($0.id)" }
        })
        #expect(requirementRefs.contains(
            matrix.externalCapabilityAccounting.ownerRequirementRef))
        #expect(matrix.executionPlan.currentTail.id
            == "physical-parallelism-cycle")
        #expect(matrix.executionPlan.currentTail.state == "active")
        #expect(Set(matrix.executionPlan.currentTail.milestoneIDs) == ["M9"])
        #expect(Set(matrix.executionPlan.currentTail.requirementRefs)
            .isSubset(of: requirementRefs))
        #expect(matrix.executionPlan.currentTail.requirementRefs == [
            "M9/parallel-runtime-and-sanitizers",
        ])
        #expect(matrix.executionPlan.nextMajorCycle.id
            == "post-physical-parallelism-cycle")
        #expect(matrix.executionPlan.nextMajorCycle.state
            == "not-scheduled")
        #expect(matrix.executionPlan.nextMajorCycle.milestoneID == "M9")
        #expect(Set(matrix.executionPlan.nextMajorCycle.entryRequirementRefs)
            .isSubset(of: requirementRefs))
        #expect(matrix.executionPlan.nextMajorCycle.entryRequirementRefs.isEmpty)
        let requirementStatuses = Dictionary(uniqueKeysWithValues:
            matrix.milestones.flatMap { milestone in
                milestone.requirements.map {
                    ("\(milestone.id)/\($0.id)", $0.status)
                }
            })
        let requirementDependencies = Dictionary(uniqueKeysWithValues:
            matrix.milestones.flatMap { milestone in
                milestone.requirements.map {
                    ("\(milestone.id)/\($0.id)", $0.dependsOnRequirements)
                }
            })
        let requirementMilestone = Dictionary(uniqueKeysWithValues:
            requirementRefs.map { reference in
                (reference, String(reference.split(separator: "/")[0]))
            })
        #expect(matrix.executionPlan.currentTail.requirementRefs.allSatisfy {
            requirementStatuses[$0] != .covered
        }, "an active closeout tail cannot retain covered requirements")
        #expect(matrix.executionPlan.currentTail.requirementRefs.allSatisfy {
            requirementMilestone[$0].map {
                matrix.executionPlan.currentTail.milestoneIDs.contains($0)
            } == true
        })
        #expect(matrix.executionPlan.nextMajorCycle.entryRequirementRefs
            .allSatisfy {
                requirementMilestone[$0]
                    == matrix.executionPlan.nextMajorCycle.milestoneID
            })
        #expect(matrix.executionPlan.currentTail.requirementRefs
            .allSatisfy { reference in
                requirementDependencies[reference, default: []].allSatisfy {
                    requirementStatuses[$0] == .covered
                }
            }, "scheduled demand cycles require covered requirement dependencies")
        let openGapIDs = Set(openGaps.map(\.id))
        #expect(openGapIDs.count == openGaps.count)
        #expect(openGaps.allSatisfy {
            requirementRefs.contains($0.requirementRef)
        }, "every open-gap observation must name a real requirement")
        let nativeGapCaseIDs = openGaps.compactMap(\.parityCase?.id)
        #expect(Set(nativeGapCaseIDs).count == nativeGapCaseIDs.count)
        #expect(Set(nativeGapCaseIDs).isDisjoint(with: parityCaseIDs))
        for gap in openGaps {
            #expect(!gap.expectedObservation.isEmpty)
            #expect(!gap.currentObservation.isEmpty)
            if gap.kind == .nativeRed {
                let parityCase = try #require(gap.parityCase)
                let reproductionTest = try #require(gap.reproductionTest)
                #expect(gap.expectedObservation != gap.currentObservation)
                #expect(testFunctionNames.contains(
                    String(reproductionTest.split(separator: "/").last!)))
                #expect(FileManager.default.fileExists(atPath:
                    Self.packageRoot.appendingPathComponent(
                        "Tests/ConcurrencyParity/\(parityCase.fixture)").path))
            } else {
                #expect(gap.parityCase == nil,
                        "only executable native RED observations carry parity cases")
            }
        }

        var caseOwners: [String: String] = [:]
        var requirementOwners: [String: String] = [:]
        var gapOwners: [String: String] = [:]
        let milestonesByID = Dictionary(uniqueKeysWithValues:
            matrix.milestones.map { ($0.id, $0) })
        for milestone in matrix.milestones {
            #expect(!milestone.title.isEmpty)
            #expect(!milestone.requirements.isEmpty)
            #expect(!milestone.dependsOn.contains(milestone.id))
            #expect(Set(milestone.dependsOn).isSubset(of: milestoneIDs))
            #expect(Set(milestone.requirements.map(\.id)).count
                == milestone.requirements.count)
            #expect(ledgerRows[milestone.id]?.status == milestone.status.rawValue,
                    "\(milestone.id) ledger and acceptance status differ")
            #expect(ledgerRows[milestone.id]?.evidence == milestone.ledgerEvidence,
                    "\(milestone.id) ledger evidence drifted from the matrix")
            #expect(ledgerRows[milestone.id]?.remainingWork
                == milestone.ledgerRemainingWork,
                "\(milestone.id) ledger remaining-work text drifted from the matrix")

            for dependency in milestone.dependsOn where milestone.status == .complete {
                #expect(milestonesByID[dependency]?.status == .complete,
                        "\(milestone.id) cannot complete before \(dependency)")
            }

            let openRequirements = milestone.requirements.filter {
                $0.status == .open
            }
            if milestone.status == .complete
                || milestone.status == .provisional
            {
                #expect(milestone.requirements.allSatisfy { $0.status == .covered },
                        "\(milestone.id) closed its scoped work without complete coverage")
            }
            if milestone.status == .provisional {
                #expect(milestone.dependsOn.contains {
                    milestonesByID[$0]?.status != .complete
                }, "a provisional milestone needs an incomplete broad dependency")
            }
            if milestone.status == .partial
                || milestone.status == .notStarted
            {
                #expect(!openRequirements.isEmpty,
                        "\(milestone.id) needs an explicit open requirement")
            }
            if milestone.status == .deferred {
                #expect(milestone.requirements.allSatisfy { $0.status == .deferred },
                        "\(milestone.id) is deferred but makes a non-deferred claim")
            }

            for requirement in milestone.requirements {
                let requirementRef = "\(milestone.id)/\(requirement.id)"
                #expect(!requirement.notes.isEmpty)
                #expect(!requirement.owners.isEmpty)
                #expect(Set(requirement.owners.map(\.rawValue)).count
                    == requirement.owners.count)
                #expect(!requirement.coverage.isEmpty)
                #expect(Set(requirement.coverage.map(\.rawValue)).count
                    == requirement.coverage.count)
                if let previous = requirementOwners.updateValue(
                    milestone.id, forKey: requirement.id,
                ) {
                    let message = "requirement '\(requirement.id)' belongs to both "
                        + previous + " and " + milestone.id
                    Issue.record(Comment(rawValue: message))
                }
                #expect(Set(requirement.dependsOnRequirements).count
                    == requirement.dependsOnRequirements.count)
                #expect(!requirement.dependsOnRequirements.contains(requirementRef))
                #expect(Set(requirement.dependsOnRequirements)
                    .isSubset(of: requirementRefs))
                for dependency in requirement.dependsOnRequirements {
                    guard let dependencyMilestone = requirementMilestone[dependency],
                          dependencyMilestone != milestone.id else { continue }
                    #expect(milestone.dependsOn.contains(dependencyMilestone),
                            "\(requirementRef) has an undeclared milestone edge to \(dependency)")
                }

                let ownedCases = Set(requirement.ownedCaseIDs)
                let reusableEvidence = Set(requirement.evidenceCaseIDs)
                #expect(ownedCases.count == requirement.ownedCaseIDs.count)
                #expect(reusableEvidence.count == requirement.evidenceCaseIDs.count)
                #expect(ownedCases.isSubset(of: parityCaseIDs),
                        "\(requirementRef) owns an unknown parity case")
                #expect(reusableEvidence.isSubset(of: parityCaseIDs),
                        "\(milestone.id)/\(requirement.id) cites an unknown parity case")
                if requirement.status == .covered {
                    #expect(!requirement.ownedCaseIDs.isEmpty
                        || !requirement.evidenceCaseIDs.isEmpty
                        || !requirement.testNames.isEmpty,
                        "covered requirements need executable evidence")
                    #expect(requirement.gapEvidenceIDs.isEmpty,
                            "covered requirements cannot retain open-gap evidence")
                    let coverageKeys = Set(requirement.coverage.map(\.rawValue))
                    #expect(Set(requirement.evidenceByCoverage.keys) == coverageKeys,
                            "\(requirementRef) must map every coverage dimension")
                    let validEvidenceReferences = Set(
                        (requirement.ownedCaseIDs + requirement.evidenceCaseIDs)
                            .map { "case:\($0)" }
                            + requirement.testNames.map { "test:\($0)" })
                    for references in requirement.evidenceByCoverage.values {
                        #expect(!references.isEmpty)
                        #expect(Set(references).isSubset(of: validEvidenceReferences),
                                "\(requirementRef) maps coverage to undeclared evidence")
                    }
                } else if requirement.status == .open {
                    #expect(!requirement.gapEvidenceIDs.isEmpty,
                            "open requirements need a precise gap observation")
                }
                for testName in requirement.testNames {
                    let functionName = testName.split(separator: "/").last.map(String.init)
                    #expect(functionName.map(testFunctionNames.contains) == true,
                            "\(milestone.id)/\(requirement.id) cites unknown test \(testName)")
                }
                for gapID in requirement.gapEvidenceIDs {
                    #expect(openGapIDs.contains(gapID),
                            "\(requirementRef) cites unknown gap evidence \(gapID)")
                    if let gap = openGaps.first(where: { $0.id == gapID }) {
                        #expect(gap.requirementRef == requirementRef,
                                "\(gapID) belongs to \(gap.requirementRef), not \(requirementRef)")
                    }
                    if let previous = gapOwners.updateValue(
                        requirementRef, forKey: gapID,
                    ) {
                        Issue.record("gap '\(gapID)' belongs to both \(previous) and \(requirementRef)")
                    }
                }
                for caseID in requirement.ownedCaseIDs {
                    let owner = "\(milestone.id)/\(requirement.id)"
                    if let previous = caseOwners.updateValue(owner, forKey: caseID) {
                        Issue.record(
                            "parity case '\(caseID)' belongs to both \(previous) and \(owner)")
                    }
                }
            }
        }

        #expect(Set(caseOwners.keys) == parityCaseIDs,
                "every parity fixture must have exactly one acceptance owner")
        #expect(Set(gapOwners.keys) == openGapIDs,
                "every open-gap observation must have exactly one acceptance owner")
        #expect(!containsDependencyCycle(matrix.milestones))
        #expect(!containsRequirementDependencyCycle(matrix.milestones))
        #expect(unreadyCoveredRequirements(
            statuses: requirementStatuses,
            dependencies: requirementDependencies,
        ).isEmpty,
        "a covered requirement cannot depend on open or deferred work")
    }

    @Test func externalCapabilityAccountingIsExactScopedAndPinned() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true,
        )
        let matrix = try JSONDecoder().decode(
            AcceptanceMatrix.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "milestone-acceptance.json")),
        )
        let accounting = matrix.externalCapabilityAccounting
        let inventoryURL = Self.packageRoot.appendingPathComponent(
            accounting.inventoryPath)
        let statusURL = Self.packageRoot.appendingPathComponent(
            accounting.statusPath)
        let inventoryData = try Data(contentsOf: inventoryURL)
        let statusData = try Data(contentsOf: statusURL)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self, from: inventoryData,
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self, from: statusData,
        )
        let parityCases = try JSONDecoder().decode(
            [AcceptanceParityCase].self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "parity-cases.json")),
        )
        let openGaps = try JSONDecoder().decode(
            [AcceptanceOpenGap].self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "open-gaps.json")),
        )
        let requirements = Dictionary(uniqueKeysWithValues:
            matrix.milestones.flatMap { milestone in
                milestone.requirements.map {
                    ("\(milestone.id)/\($0.id)", $0)
                }
            })
        let gaps = Dictionary(uniqueKeysWithValues:
            openGaps.map { ($0.id, $0) })
        let parityCaseIDs = Set(parityCases.map(\.id))
        let testFunctionNames = try loadTestFunctionNames()

        #expect(inventory.schemaVersion == accounting.inventorySchemaVersion)
        #expect(status.schemaVersion == accounting.statusSchemaVersion)
        #expect(inventory.schemaVersion == 1)
        #expect(status.schemaVersion == 1)
        #expect(status.inventoryPath == accounting.inventoryPath)
        #expect(!inventory.scope.complete)
        #expect(!inventory.scope.adapterRouteIsSupportEvidence)
        #expect(!inventory.scope.excluded.isEmpty,
                "an incomplete generated denominator must list its exclusions")
        #expect(inventory.declarations.count
            == inventory.summary.declarationCount)
        let inventoryIDs = inventory.declarations.map(\.id)
        #expect(Set(inventoryIDs).count == inventoryIDs.count)
        #expect(inventoryIDs.allSatisfy {
            $0.range(
                of: #"^swift-concurrency-api-v1:[0-9a-f]{64}$"#,
                options: .regularExpression,
            ) != nil
        })
        let actualDomainCounts = Dictionary(grouping:
            inventory.declarations, by: \.domain).mapValues(\.count)
        #expect(actualDomainCounts == inventory.summary.declarationsByDomain)

        let inventorySHA256 = sha256(inventoryData)
        #expect(status.inventorySHA256 == inventorySHA256,
                "SDK inventory drift must force an authored status review")
        #expect(Set(status.statusModel.implementationStatuses)
            == Set(CapabilityImplementationStatus.allCases.map(\.rawValue)))
        #expect(Set(status.statusModel.implementationStatuses).count
            == status.statusModel.implementationStatuses.count)
        #expect(Set(status.statusModel.verificationStatuses)
            == Set(CapabilityVerificationStatus.allCases.map(\.rawValue)))
        #expect(Set(status.statusModel.verificationStatuses).count
            == status.statusModel.verificationStatuses.count)
        #expect(!status.statusModel.rule.isEmpty)
        #expect(status.defaultInterfaceClaim.implementationStatus == .unreviewed)
        #expect(status.defaultInterfaceClaim.verificationStatus == .none)

        func validateClaim(_ claim: CapabilityClaim, label: String) {
            #expect(!claim.notes.isEmpty, "\(label) needs an explicit rationale")
            guard let requirement = requirements[claim.requirementRef] else {
                Issue.record("\(label) cites unknown requirement \(claim.requirementRef)")
                return
            }
            let declaredCases = Set(
                requirement.ownedCaseIDs + requirement.evidenceCaseIDs)
            #expect(Set(claim.evidenceCaseIDs).isSubset(of: parityCaseIDs))
            #expect(Set(claim.evidenceCaseIDs).isSubset(of: declaredCases),
                    "\(label) cites cases outside \(claim.requirementRef)")
            #expect(Set(claim.testNames).isSubset(of: Set(requirement.testNames)),
                    "\(label) cites tests outside \(claim.requirementRef)")
            for testName in claim.testNames {
                let functionName = testName.split(separator: "/").last
                    .map(String.init) ?? ""
                #expect(testFunctionNames.contains(functionName),
                        "\(label) cites unknown test \(testName)")
            }
            for gapID in claim.gapEvidenceIDs {
                #expect(gaps[gapID]?.requirementRef == claim.requirementRef,
                        "\(label) cites a gap owned by another requirement")
            }

            let hasEvidence = !claim.evidenceCaseIDs.isEmpty
                || !claim.testNames.isEmpty
            switch claim.implementationStatus {
            case .runtimeSupported, .preflightOnly:
                #expect(hasEvidence)
                #expect(claim.verificationStatus == .nativeParity
                    || claim.verificationStatus == .focusedOnly)
                #expect(claim.gapEvidenceIDs.isEmpty)
            case .diagnosedUnsupported:
                #expect(hasEvidence && !claim.gapEvidenceIDs.isEmpty)
                #expect(claim.verificationStatus == .focusedOnly
                    || claim.verificationStatus == .nativeRed)
            case .unreviewed:
                #expect(!claim.gapEvidenceIDs.isEmpty)
                #expect(claim.verificationStatus == .none)
            case .knownDivergence:
                #expect(!claim.gapEvidenceIDs.isEmpty)
                #expect(claim.verificationStatus == .none
                    || claim.verificationStatus == .nativeRed)
            case .excludedCompilerABI:
                #expect(claim.verificationStatus == .none)
            case .deferred:
                #expect(claim.verificationStatus == .none)
                #expect(!claim.gapEvidenceIDs.isEmpty
                    || requirement.status == .deferred)
            }
            switch claim.verificationStatus {
            case .nativeParity, .focusedOnly:
                #expect(hasEvidence)
            case .nativeRed:
                #expect(hasEvidence && !claim.gapEvidenceIDs.isEmpty)
                #expect(claim.gapEvidenceIDs.allSatisfy {
                    gaps[$0]?.kind == .nativeRed
                })
            case .none:
                #expect(claim.implementationStatus != .runtimeSupported
                    && claim.implementationStatus != .preflightOnly)
            }
        }

        validateClaim(status.defaultInterfaceClaim, label: "default interface claim")
        var overridesByID: [String: CapabilityClaim] = [:]
        for override in status.interfaceOverrides {
            #expect(Set(inventoryIDs).contains(override.id),
                    "interface override cites an unknown generated declaration")
            if overridesByID.updateValue(override.claim, forKey: override.id) != nil {
                Issue.record("duplicate interface override \(override.id)")
            }
            validateClaim(override.claim, label: "interface override \(override.id)")
        }
        let resolvedInterfaceClaims = inventoryIDs.map {
            overridesByID[$0] ?? status.defaultInterfaceClaim
        }
        #expect(resolvedInterfaceClaims.count == inventory.declarations.count)
        let interfaceImplementationCounts = Dictionary(grouping:
            resolvedInterfaceClaims, by: \.implementationStatus).mapValues(\.count)
        let interfaceVerificationCounts = Dictionary(grouping:
            resolvedInterfaceClaims, by: \.verificationStatus).mapValues(\.count)
        #expect(interfaceImplementationCounts.values.reduce(0, +)
            == inventory.declarations.count)
        #expect(interfaceVerificationCounts.values.reduce(0, +)
            == inventory.declarations.count)
        let resolvedByID = Dictionary(uniqueKeysWithValues:
            zip(inventoryIDs, resolvedInterfaceClaims))
        if requirements["M7/generated-signatures-and-preflight"]?.status
            == .covered
        {
            #expect(resolvedInterfaceClaims.allSatisfy {
                $0.implementationStatus != .unreviewed
            }, "M7 cannot close while generated declarations are unreviewed")
        }
        if requirements["M4/remaining-task-group-surface"]?.status == .covered {
            let unreviewedTaskGroupRows = inventory.declarations.filter {
                ($0.domain == "task-group-member"
                    || $0.domain == "task-group-iterator-member")
                    && resolvedByID[$0.id]?.implementationStatus == .unreviewed
            }
            #expect(unreviewedTaskGroupRows.isEmpty,
                "M4 group-surface closure requires every generated group row to be reviewed")
        }

        let semanticIDs = status.semanticCapabilities.map(\.id)
        #expect(Set(semanticIDs).count == semanticIDs.count)
        let expectedSemanticCatalog = [
            "core-async-await-language",
            "task-owned-evaluation-context",
            "unstructured-task-runtime",
            "task-suspension-sleep-and-cancellation-handlers",
            "async-let-structured-lifetime",
            "task-group-core-semantics",
            "task-group-complete-generated-surface",
            "logical-mainactor-and-default-executors",
            "actor-declaration-safety-boundary",
            "actor-identity-storage-and-serial-executor",
            "actor-reentrancy-and-isolated-dispatch",
            "compiler-backed-concurrency-diagnostics",
            "sendable-checking",
            "async-sequence-stream-and-continuation-runtime",
            "swiftui-view-owned-async-lifecycle",
            "physical-parallel-execution",
        ]
        #expect(status.semanticCatalog.id == "project-concurrency-roadmap-v1")
        #expect(status.semanticCatalog.version == 1)
        #expect(!status.semanticCatalog.completeForAcceptanceScope)
        #expect(!status.semanticCatalog.scope.isEmpty)
        #expect(!status.semanticCatalog.excluded.isEmpty)
        #expect(status.semanticCatalog.capabilityIDs == expectedSemanticCatalog)
        #expect(semanticIDs == status.semanticCatalog.capabilityIDs)
        for capability in status.semanticCapabilities {
            validateClaim(
                capability.claim,
                label: "semantic capability \(capability.id)",
            )
        }
        #expect(requirements.keys.contains(
            matrix.externalCapabilityAccounting.ownerRequirementRef))
    }

    @Test func capabilityAccountingValidatorFailsClosedOnManifestDrift() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventoryURL = manifestRoot.appendingPathComponent(
            "generated-concurrency-api.json")
        let statusURL = manifestRoot.appendingPathComponent(
            "concurrency-capability-status.json")
        let acceptanceURL = manifestRoot.appendingPathComponent(
            "milestone-acceptance.json")
        let gapsURL = manifestRoot.appendingPathComponent("open-gaps.json")
        let parityURL = manifestRoot.appendingPathComponent("parity-cases.json")
        let canonicalInventoryPath =
            "Tests/ConcurrencyParity/Manifests/generated-concurrency-api.json"
        let canonicalStatusPath =
            "Tests/ConcurrencyParity/Manifests/concurrency-capability-status.json"

        let accepted = try runCapabilityValidator(
            inventoryURL: inventoryURL,
            statusURL: statusURL,
            acceptanceURL: acceptanceURL,
            gapsURL: gapsURL,
            parityURL: parityURL,
            inventoryPath: canonicalInventoryPath,
            statusPath: canonicalStatusPath)
        #expect(accepted.status == 0,
            Comment(rawValue: accepted.standardError + accepted.standardOutput))
        let acceptedPayload = try #require(
            JSONSerialization.jsonObject(with: Data(accepted.standardOutput.utf8))
                as? [String: Any])
        #expect(acceptedPayload["valid"] as? Bool == true)
        #expect((acceptedPayload["errors"] as? [String])?.isEmpty == true)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-capability-validator-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporaryInventory = directory.appendingPathComponent("inventory.json")
        let temporaryStatus = directory.appendingPathComponent("status.json")
        let inventoryData = try Data(contentsOf: inventoryURL)
        let statusData = try Data(contentsOf: statusURL)
        try inventoryData.write(to: temporaryInventory)

        func rejected(
            statusObject: [String: Any]? = nil,
            rawStatus: Data? = nil,
            containing fragment: String
        ) throws {
            if let rawStatus {
                try rawStatus.write(to: temporaryStatus)
            } else {
                let data = try JSONSerialization.data(
                    withJSONObject: try #require(statusObject),
                    options: [.prettyPrinted, .sortedKeys])
                try data.write(to: temporaryStatus)
            }
            let result = try runCapabilityValidator(
                inventoryURL: temporaryInventory,
                statusURL: temporaryStatus,
                acceptanceURL: acceptanceURL,
                gapsURL: gapsURL,
                parityURL: parityURL,
                inventoryPath: canonicalInventoryPath,
                statusPath: canonicalStatusPath)
            #expect(result.status != 0)
            let payload = try #require(
                JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
                    as? [String: Any])
            #expect(payload["valid"] as? Bool == false)
            #expect((payload["errors"] as? [String])?.joined(separator: "\n")
                .contains(fragment) == true)
        }

        var pinMismatch = try #require(
            JSONSerialization.jsonObject(with: statusData) as? [String: Any])
        pinMismatch["inventorySHA256"] = String(repeating: "0", count: 64)
        try rejected(
            statusObject: pinMismatch,
            containing: "inventory pin mismatch")

        var duplicateOverride = try #require(
            JSONSerialization.jsonObject(with: statusData) as? [String: Any])
        let inventoryObject = try #require(
            JSONSerialization.jsonObject(with: inventoryData) as? [String: Any])
        let firstDeclaration = try #require(
            (inventoryObject["declarations"] as? [[String: Any]])?.first)
        let firstID = try #require(firstDeclaration["id"] as? String)
        var override = try #require(
            duplicateOverride["defaultInterfaceClaim"] as? [String: Any])
        override["id"] = firstID
        duplicateOverride["interfaceOverrides"] = [override, override]
        try rejected(
            statusObject: duplicateOverride,
            containing: "duplicate capability overrides")

        try rejected(
            rawStatus: Data("{".utf8),
            containing: "JSON::ParserError")
    }

    @Test func taskInstanceGeneratedSurfaceHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let taskInstanceIDs = Set(inventory.declarations.compactMap {
            $0.domain == "task-instance-member" ? $0.id : nil
        })
        let taskInstanceClaims = status.interfaceOverrides.filter {
            taskInstanceIDs.contains($0.id)
        }

        #expect(taskInstanceIDs.count == 11,
            "the active SDK Task-instance denominator changed")
        #expect(Set(taskInstanceClaims.map(\.id)) == taskInstanceIDs,
            "every Task-instance overload needs an authored disposition")
        #expect(taskInstanceClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskStaticGeneratedSurfaceHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let taskStaticIDs = Set(inventory.declarations.compactMap {
            $0.domain == "task-static-member" ? $0.id : nil
        })
        let taskStaticClaims = status.interfaceOverrides.filter {
            taskStaticIDs.contains($0.id)
        }

        #expect(taskStaticIDs.count == 25,
            "the active SDK Task-static denominator changed")
        #expect(Set(taskStaticClaims.map(\.id)) == taskStaticIDs,
            "every Task-static overload needs an authored disposition")
        #expect(taskStaticClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })

        let nameRow = try #require(inventory.declarations.first {
            $0.domain == "task-static-member" && $0.name == "name"
        })
        #expect(nameRow.adapterIntrinsic == "name")
        let nameClaim = try #require(taskStaticClaims.first {
            $0.id == nameRow.id
        })
        #expect(nameClaim.implementationStatus == .runtimeSupported)
        #expect(nameClaim.verificationStatus == .nativeParity)
        #expect(nameClaim.requirementRef
            == "M7/generated-signatures-and-preflight")
        #expect(nameClaim.evidenceCaseIDs == ["task-name"])
        #expect(nameClaim.gapEvidenceIDs.isEmpty)
    }

    @Test func taskImmediateHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let names: Set<String> = ["immediate", "immediateDetached"]
        let rows = inventory.declarations.filter {
            $0.domain == "task-static-member" && names.contains($0.name)
        }
        let expectedIDs: Set<String> = [
            "swift-concurrency-api-v1:021dc3b0bb2762c3122c3d9c0e07b72064ba03e8d7380d5ed12ab97b1ba35b32",
            "swift-concurrency-api-v1:4e24728354412bd22e0c5685fea624ea5ea6aad2b4989b68180c674a4fa9aa35",
            "swift-concurrency-api-v1:d487a795b81ef9c139c1f0e58bfa42a6f70ebe8ded2fda7c8095d063b07820e5",
            "swift-concurrency-api-v1:e04b79e2b727826f1f84cc6409fa0c935c9b25352504275cabd568c3d3d6a1e3",
        ]
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 4,
            "the active SDK Task.immediate denominator changed")
        #expect(ids == expectedIDs,
            "the active SDK Task.immediate identities changed")
        #expect(Dictionary(grouping: rows, by: \.name).mapValues(\.count) == [
            "immediate": 2,
            "immediateDetached": 2,
        ])
        #expect(rows.count {
            $0.declaration.contains("() async throws -> Success")
        } == 2)
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == $0.name
                && $0.declaration.contains(
                    "@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)")
                && $0.declaration.contains("name: Swift.String? = nil")
                && $0.declaration.contains(
                    "priority: _Concurrency.TaskPriority? = nil")
                && $0.declaration.contains(
                    "executorPreference taskExecutor: consuming (any _Concurrency.TaskExecutor)? = nil")
                && $0.declaration.contains("@_implicitSelfCapture")
                && $0.declaration.contains(
                    "@_inheritActorContext(always) operation: sending @escaping @isolated(any)")
        }, "Task.immediate interface shape changed")
        #expect(Set(claims.map(\.id)) == ids,
            "all Task.immediate rows need an authored disposition")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef
                    == "M7/generated-signatures-and-preflight"
                && $0.evidenceCaseIDs == ["task-immediate"]
                && $0.testNames.contains(
                    "GeneratedTaskSurfaceTests/immediateTaskKindsRunTheirPrefixBeforeConstructionReturns")
                && $0.testNames.contains(
                    "GeneratedTaskSurfaceTests/immediateTaskKindsUseDistinctRuntimeInheritanceAndCleanUp")
                && $0.testNames.contains(
                    "GeneratedTaskSurfaceTests/immediateTaskKindsPreserveOperationExecutorAcrossSuspension")
                && $0.testNames.contains(
                    "GeneratedTaskSurfaceTests/immediateTaskKindsRejectUnsupportedOperationExecutors")
                && $0.testNames.contains(
                    "GeneratedTaskSurfaceTests/nonNilImmediateTaskExecutorPreferencesFailClosed")
                && $0.testNames.contains(
                    "GeneratedTaskSurfaceTests/immediateTaskKindsDoNotUseSynchronousCompatibility")
                && $0.gapEvidenceIDs
                    == ["generated-concurrency-signatures-and-preflight"]
                && $0.notes.contains("explicit-nil")
                && $0.notes.contains("MainActor")
                && $0.notes.contains("TaskExecutor")
                && $0.notes.contains("@isolated(any)")
        }, "Task.immediate rows must retain executor and actor gaps")
    }

    @Test func topLevelAsyncHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let rows = inventory.declarations.filter {
            $0.domain == "top-level-function" && $0.name == "async"
        }
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 2,
            "the active SDK top-level async denominator changed")
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == "unstructuredTask"
                && $0.declaration.contains("priority: _Concurrency.TaskPriority? = nil")
                && $0.declaration.contains("@_inheritActorContext")
                && $0.declaration.contains("@isolated(any) @Sendable")
                && $0.declaration.contains(") -> _Concurrency.Task<Success,")
        }, "top-level async call shape changed")
        #expect(rows.count {
            $0.declaration.contains("() async -> Success)")
                && $0.declaration.contains("Task<Success, Swift.Never>")
        } == 1)
        #expect(rows.count {
            $0.declaration.contains("() async throws -> Success)")
                && $0.declaration.contains("Task<Success, any Swift.Error>")
        } == 1)
        #expect(Set(claims.map(\.id)) == ids,
            "both top-level async overloads need authored dispositions")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef
                    == "M7/generated-signatures-and-preflight"
                && $0.evidenceCaseIDs == ["top-level-async"]
                && $0.gapEvidenceIDs
                    == ["generated-concurrency-signatures-and-preflight"]
                && $0.notes.contains("@isolated(any)")
        }, "top-level async must retain its arbitrary-actor executor gap")
    }

    @Test func topLevelDetachedAliasesHaveExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let aliasNames: Set<String> = ["asyncDetached", "detach"]
        let rows = inventory.declarations.filter {
            $0.domain == "top-level-function" && aliasNames.contains($0.name)
        }
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 4,
            "the active SDK top-level detached-alias denominator changed")
        #expect(Dictionary(grouping: rows, by: \.name).mapValues(\.count) == [
            "asyncDetached": 2,
            "detach": 2,
        ])
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == "detachedTask"
                && $0.declaration.contains(
                    "priority: _Concurrency.TaskPriority? = nil")
                && $0.declaration.contains("@_inheritActorContext")
                && $0.declaration.contains("@isolated(any) @Sendable")
                && $0.declaration.contains(") -> _Concurrency.Task<Success,")
        }, "top-level detached-alias call shape changed")
        #expect(rows.count {
            $0.declaration.contains("() async -> Success)")
                && $0.declaration.contains("Task<Success, Swift.Never>")
        } == 2)
        #expect(rows.count {
            $0.declaration.contains("() async throws -> Success)")
                && $0.declaration.contains("Task<Success, any Swift.Error>")
        } == 2)
        #expect(Set(claims.map(\.id)) == ids,
            "all four detached aliases need authored dispositions")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef
                    == "M7/generated-signatures-and-preflight"
                && $0.evidenceCaseIDs == ["top-level-detached-aliases"]
                && $0.gapEvidenceIDs
                    == ["generated-concurrency-signatures-and-preflight"]
                && $0.notes.contains("@isolated(any)")
        }, "detached aliases must retain their arbitrary-actor executor gap")
    }

    @Test func topLevelCancellationHandlersHaveExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let rows = inventory.declarations.filter {
            $0.domain == "top-level-function"
                && $0.name == "withTaskCancellationHandler"
        }
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 2,
            "the active SDK cancellation-handler denominator changed")
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == "withTaskCancellationHandler"
                && $0.declaration.contains("async rethrows")
        })
        #expect(Set(claims.map(\.id)) == ids,
            "both public cancellation-handler overloads need dispositions")

        let deprecatedRow = try #require(rows.first {
            $0.declaration.contains("handler: @Sendable")
                && !$0.declaration.contains("isolation: isolated")
        })
        let deprecatedClaim = try #require(claims.first {
            $0.id == deprecatedRow.id
        })
        #expect(deprecatedClaim.implementationStatus == .runtimeSupported)
        #expect(deprecatedClaim.verificationStatus == .nativeParity)
        #expect(deprecatedClaim.requirementRef
            == "M3/suspension-and-cancellation-semantics")
        #expect(deprecatedClaim.evidenceCaseIDs
            .contains("task-cancellation-handler-active"))
        #expect(deprecatedClaim.gapEvidenceIDs.isEmpty)

        let modernRow = try #require(rows.first {
            $0.declaration.contains("operation: () async throws")
                && $0.declaration.contains("isolation: isolated")
        })
        let modernClaim = try #require(claims.first {
            $0.id == modernRow.id
        })
        #expect(modernClaim.implementationStatus == .knownDivergence)
        #expect(modernClaim.verificationStatus == .none)
        #expect(modernClaim.requirementRef
            == "M7/generated-signatures-and-preflight")
        #expect(modernClaim.gapEvidenceIDs
            == ["generated-concurrency-signatures-and-preflight"])
    }

    @Test func topLevelTaskGroupScopesHaveExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let expectedNames: Set<String> = [
            "withDiscardingTaskGroup",
            "withTaskGroup",
            "withThrowingDiscardingTaskGroup",
            "withThrowingTaskGroup",
        ]
        let rows = inventory.declarations.filter {
            $0.domain == "top-level-function"
                && expectedNames.contains($0.name)
        }
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 4,
            "the active SDK task-group scope denominator changed")
        #expect(Set(rows.map(\.name)) == expectedNames)
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == $0.name
                && $0.declaration.contains("isolation: isolated")
                && $0.declaration.contains("body:")
                && $0.declaration.contains(") async")
        })
        #expect(Set(claims.map(\.id)) == ids,
            "every public task-group scope function needs a disposition")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef == "M4/remaining-task-group-surface"
                && $0.evidenceCaseIDs.contains("task-group-state-properties")
                && $0.gapEvidenceIDs
                    == ["remaining-generated-task-group-surface"]
        }, "scope rows must not overclaim arbitrary actor isolation")
    }

    @Test func compilerABITopLevelFunctionsHaveExplicitExclusions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let abiIDs: Set<String> = [
            "swift-concurrency-api-v1:ae7ac0cdc015b5f5ea24df9083ccee6beda64febf71851ba4dff3642c91ea612",
            "swift-concurrency-api-v1:d0005a853143eca6ad91ef1ad45aa197f336a7544aa2e5fa85fe829bc1cadc15",
            "swift-concurrency-api-v1:fa569a4257843965b00c9f6eaeaba33cfa23d0c6f222ee3b6ce790fe0f29dba4",
            "swift-concurrency-api-v1:3988fa6c1b391b6c90ab2f0328df760a03f5f34c74397279cc4a14bd79a66395",
            "swift-concurrency-api-v1:790463e48556316860c9e12373814f1dfb0f18246ecb48ef1d4192d2e2a34cae",
            "swift-concurrency-api-v1:bb5ac129e02bd91bc1f831e352a59e18d2e81f2365850285fd89758d2e745365",
            "swift-concurrency-api-v1:d61bec39af1da5b8a85a3f973172c1bf668efe42061aa55cb160e1ae63e8dfa3",
            "swift-concurrency-api-v1:95d39c1dd3a56fa5190847a101b6630c7683a2ef4dd5319300ab6b054b392a57",
            "swift-concurrency-api-v1:6ec23c60ee0f39519d6228feb03589eda9b48ab5b11bfeac627061ceb56c2fb3",
            "swift-concurrency-api-v1:449e7aa9091e725cd3aa4cb5ee9aa8c8bd744f5e3138fa6b57299cfc3c68932e",
            "swift-concurrency-api-v1:c6534750996d7c10bae369bc3326df98bf5c58b8e9afbfc4d9ad0c09907c0ea9",
            "swift-concurrency-api-v1:be4a18efe3c63fcfac9505546b61e166f4a11d2f5f9cfa3410cabd93ef07481f",
            "swift-concurrency-api-v1:08910be9c9688c2b10e2edcfb5ab8ad38c03efb41b18948913a2b9e627765339",
            "swift-concurrency-api-v1:713a8ac9084ace7592176c771c8487768e490834425f7fb05baee66e43b9502a",
            "swift-concurrency-api-v1:ddb9f592b478044965fda17e7ff3156ef22e27c6f2063f5ea7ab411a5a6f3fef",
            "swift-concurrency-api-v1:8a90282b0e2fc956ba15debf8e5e2b27e51c9fcdcaa386555ea2dd44ebad19cc",
            "swift-concurrency-api-v1:53ce59be08be99127ebe72fe2954ae73ab07edee2b286daf8030f50057e17787",
            "swift-concurrency-api-v1:bb7579c72b73c8dcad105de413ffa8fbf5e1e65249c048297e3c5fed7bc3a0b1",
            "swift-concurrency-api-v1:78fa49208bf6d0965b512a3a2ed81d203057a80c3da6a74285842cb05a811534",
            "swift-concurrency-api-v1:8619189ab2282a660a25224b1c32cf3576d7de8ca75da14611d2e931b77873d5",
            "swift-concurrency-api-v1:1ae7bd5cde536a626f65aab0632647ed696adf66522d52bc42b639ec961c850a",
            "swift-concurrency-api-v1:c17841d7a50cbd49f506ada44d303128aa3cdeea3fbbe64641cb0ea5c995f9dc",
            "swift-concurrency-api-v1:b6543e08eeb1740e3f524edf466dc4880881c936f6ea7eb0d010c9dad42e1cfa",
            "swift-concurrency-api-v1:05029193ba47181a904e413c13eeef800c0132c6db0bc67cd5f4bd1bb8b26cab",
            "swift-concurrency-api-v1:f408a13f7e8c0b13a716326fea989cd2ba56c2eefb213242776c3a50f3e8ab11",
            "swift-concurrency-api-v1:eb7d5306879d6fc555b7189620041c890004bdef07c803daa0218e00a7ec9715",
        ]
        let testingHookID =
            "swift-concurrency-api-v1:75560cb6e0a7a099f0a8150723dc13a0cc65e7c2e76faec35eb7fa38cd1d6805"
        let routedSourceWrapperID =
            "swift-concurrency-api-v1:4761cd66b86d6ff1f8185aee2e85480eff7a80c9ff76821cd244747b11637c50"
        let underscoreRows = inventory.declarations.filter {
            $0.domain == "top-level-function" && $0.name.hasPrefix("_")
        }
        let expectedIDs = abiIDs.union([
            testingHookID, routedSourceWrapperID,
        ])

        #expect(underscoreRows.count == 28,
            "the active SDK underscore-prefixed top-level denominator changed")
        #expect(Set(underscoreRows.map(\.id)) == expectedIDs)
        #expect(underscoreRows.filter {
            abiIDs.contains($0.id) || $0.id == testingHookID
        }.allSatisfy { $0.adapterIntrinsic == nil },
        "compiler/runtime ABI rows must remain unrouted")

        let abiRows = underscoreRows.filter { abiIDs.contains($0.id) }
        #expect(abiRows.count == 26)
        #expect(abiRows.allSatisfy {
            $0.name == "_abiEnableAwaitContinuation"
                || $0.declaration.contains("Builtin.")
                || $0.declaration.contains("@_silgen_name")
                || $0.declaration.contains("@_unsafeInheritExecutor")
        }, "ABI exclusions need compiler/runtime-only declaration evidence")
        let abiClaims = status.interfaceOverrides.filter {
            abiIDs.contains($0.id)
        }
        #expect(Set(abiClaims.map(\.id)) == abiIDs)
        #expect(abiClaims.allSatisfy {
            $0.implementationStatus == .excludedCompilerABI
                && $0.verificationStatus == .none
                && $0.requirementRef == "M7/generated-signatures-and-preflight"
        })

        let hookRow = try #require(underscoreRows.first {
            $0.id == testingHookID
        })
        #expect(hookRow.name == "_swift_createJobForTestingOnly")
        #expect(hookRow.declaration.contains("-> _Concurrency.ExecutorJob"))
        let hookClaim = try #require(status.interfaceOverrides.first {
            $0.id == testingHookID
        })
        #expect(hookClaim.implementationStatus == .deferred)
        #expect(hookClaim.verificationStatus == .none)
        #expect(hookClaim.requirementRef == "M9/parallel-runtime-and-sanitizers")
        #expect(!abiIDs.contains(hookClaim.id),
            "the public testing hook must not be hidden as compiler ABI")

        #expect(underscoreRows.contains { $0.id == routedSourceWrapperID },
            "source-callable underscore wrappers must remain in the denominator")
        #expect(status.defaultInterfaceClaim.implementationStatus == .unreviewed)
        #expect(status.defaultInterfaceClaim.verificationStatus == .none)
    }

    @Test func priorityEscalationHandlersHaveExplicitReviewedDispositions()
    throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let priorityEscalationWrapperID =
            "swift-concurrency-api-v1:4761cd66b86d6ff1f8185aee2e85480eff7a80c9ff76821cd244747b11637c50"
        let priorityEscalationID =
            "swift-concurrency-api-v1:d4007c426222ed20d7f662c79a68edc150bd24165630f580e47b238f1d8c825d"
        let priorityEscalationRows = inventory.declarations.filter {
            [priorityEscalationWrapperID, priorityEscalationID].contains($0.id)
        }
        #expect(priorityEscalationRows.count == 2)
        #expect(priorityEscalationRows.allSatisfy {
            $0.adapterIntrinsic == "withTaskPriorityEscalationHandler"
        })
        let priorityEscalation = try #require(
            priorityEscalationRows.first { $0.id == priorityEscalationID })
        #expect(priorityEscalation.declaration
            .contains("nonisolated(nonsending)"))
        #expect(priorityEscalation.declaration.contains("async throws(E)"))
        let priorityEscalationWrapper = try #require(
            priorityEscalationRows.first {
                $0.id == priorityEscalationWrapperID
            })
        #expect(priorityEscalationWrapper.name
            == "_isolatedParameter_withTaskPriorityEscalationHandler")
        #expect(priorityEscalationWrapper.declaration.contains("@abi(func"))
        #expect(priorityEscalationWrapper.declaration
            .contains("isolation: isolated"))
        let priorityEscalationClaims = status.interfaceOverrides.filter {
            [priorityEscalationWrapperID, priorityEscalationID].contains($0.id)
        }
        #expect(priorityEscalationClaims.count == 2)
        #expect(priorityEscalationClaims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef
                    == "M7/generated-signatures-and-preflight"
                && $0.evidenceCaseIDs
                    .contains("task-priority-escalation-handler")
        })
    }

    @Test func taskExecutorPreferenceHasExplicitReviewedDisposition() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let expectedID =
            "swift-concurrency-api-v1:e68748f7bb9c746670485d2f0151129a63ad918994e692bede2ca9d7e622cd05"
        let row = try #require(inventory.declarations.first {
            $0.id == expectedID
        })

        #expect(row.domain == "top-level-function")
        #expect(row.name == "withTaskExecutorPreference")
        #expect(row.adapterIntrinsic == "withTaskExecutorPreference")
        #expect(row.declaration.contains(
            "withTaskExecutorPreference<T, Failure>"))
        #expect(row.declaration.contains(
            "_ taskExecutor: (any _Concurrency.TaskExecutor)?"))
        #expect(row.declaration.contains(
            "isolation: isolated (any _Concurrency.Actor)? = #isolation"))
        #expect(row.declaration.contains(
            "operation: () async throws(Failure) -> T"))
        #expect(row.declaration.contains(
            ") async throws(Failure) -> T where Failure : Swift.Error"))

        let claim = try #require(status.interfaceOverrides.first {
            $0.id == expectedID
        })
        #expect(claim.implementationStatus == .knownDivergence)
        #expect(claim.verificationStatus == .none)
        #expect(claim.requirementRef
            == "M7/generated-signatures-and-preflight")
        #expect(claim.evidenceCaseIDs
            == ["with-task-executor-preference-nil"])
        #expect(claim.testNames.contains(
            "AsyncExecutionTests/taskExecutorPreferenceNilScopePreservesTaskStateAndCleansUp"))
        #expect(claim.testNames.contains(
            "AsyncExecutionTests/taskExecutorPreferenceUnsupportedShapesFailClosed"))
        #expect(claim.testNames.contains(
            "AsyncExecutionTests/taskExecutorPreferenceRejectsStaleRuntimeContext"))
        #expect(claim.gapEvidenceIDs
            == ["generated-concurrency-signatures-and-preflight"])
        #expect(claim.notes.contains("no ambient custom TaskExecutor"))
        #expect(claim.notes.contains(
            "bare unqualified direct global async operation"))
        #expect(claim.notes.contains("plain explicit nonisolated"))
        #expect(claim.notes.contains(
            "no declaration-level executor preference"))
        #expect(claim.notes.contains("inherits an ambient custom executor"))
        #expect(claim.notes.contains(
            "local aliases or function-value conversions"))
        #expect(claim.notes.contains("@concurrent"))
        #expect(claim.notes.contains("nonisolated(nonsending)"))
        #expect(claim.notes.contains("closure-expression operations"))
    }

    @Test func extractIsolationHasExplicitReviewedDisposition() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let expectedID =
            "swift-concurrency-api-v1:c8849676233060c2f6364bb847db1bac6c2b6ddcae80a6da3269d3adda052bb8"
        let row = try #require(inventory.declarations.first {
            $0.id == expectedID
        })

        #expect(row.domain == "top-level-function")
        #expect(row.name == "extractIsolation")
        #expect(row.adapterIntrinsic == "extractIsolation")
        #expect(row.declaration.contains(
            "extractIsolation<each Arg, Result>"))
        #expect(row.declaration.contains(
            "_ fn: @escaping @isolated(any)"))
        #expect(row.declaration.contains(
            "(repeat each Arg) async throws -> Result"))
        #expect(row.declaration.contains(
            "-> (any _Concurrency.Actor)?"))
        #expect(row.declaration.contains(
            "Use `.isolation` on @isolated(any) closure values instead."))

        let claim = try #require(status.interfaceOverrides.first {
            $0.id == expectedID
        })
        #expect(claim.implementationStatus == .knownDivergence)
        #expect(claim.verificationStatus == .none)
        #expect(claim.requirementRef
            == "M7/generated-signatures-and-preflight")
        #expect(claim.evidenceCaseIDs == ["extract-isolation-nonisolated"])
        #expect(claim.testNames.contains(
            "AsyncExecutionTests/extractIsolationReflectsExplicitNonisolatedWithoutTaskOrCall"))
        #expect(claim.testNames.contains(
            "AsyncExecutionTests/extractIsolationUnsupportedProvenanceFailsClosed"))
        #expect(claim.gapEvidenceIDs
            == ["generated-concurrency-signatures-and-preflight"])
        #expect(claim.notes.contains("synchronous metadata inspection"))
        #expect(claim.notes.contains(
            "bare unqualified direct global async function declarations"))
        #expect(claim.notes.contains("plain explicit nonisolated"))
        #expect(claim.notes.contains("without invoking the operation"))
        #expect(claim.notes.contains("MainActor"))
        #expect(claim.notes.contains("local aliases"))
        #expect(claim.notes.contains("qualified or parenthesized references"))
        #expect(claim.notes.contains("function-value conversions"))
        #expect(claim.notes.contains("member references"))
        #expect(claim.notes.contains("known divergence"))
    }

    @Test func continuationEntryPointsHaveExplicitReviewedDispositions()
    throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let expected: [String: String] = [
            "swift-concurrency-api-v1:4a06fa1c6a62c68b34e00e0b05359c361239a7bd4697477916bbba908ed12453":
                "withCheckedContinuation",
            "swift-concurrency-api-v1:ace6ad5d810bcf9eda3b3214d498b783a36385621bc9361241fba14afb9f1e39":
                "withCheckedThrowingContinuation",
            "swift-concurrency-api-v1:1c6b71ba2592eb2a5841edbe5c173bf0dcc5801237920669367ca47a9797fcc3":
                "withUnsafeContinuation",
            "swift-concurrency-api-v1:16b269f49b82c403312e3cbfde1b6db496f06dc96b32e22d8a0ede15a94167d7":
                "withUnsafeThrowingContinuation",
        ]
        let publicContinuationRows = inventory.declarations.filter {
            $0.domain == "top-level-function"
                && !$0.name.hasPrefix("_")
                && $0.name.contains("Continuation")
        }
        let rows = inventory.declarations.filter { expected[$0.id] != nil }

        #expect(Set(publicContinuationRows.map(\.id)) == Set(expected.keys),
            "the public continuation entry-point denominator changed")
        #expect(rows.count == 4)
        #expect(Set(rows.map(\.id)) == Set(expected.keys))
        #expect(rows.allSatisfy {
            $0.domain == "top-level-function"
                && $0.container == "_Concurrency"
                && $0.name == expected[$0.id]
                && $0.declaration.contains(
                    "isolation: isolated (any _Concurrency.Actor)? = #isolation")
                && $0.declaration.contains("async")
                && $0.declaration.contains("-> sending T")
        })
        let checked = try #require(rows.first {
            $0.name == "withCheckedContinuation"
        })
        #expect(checked.adapterIntrinsic == "withCheckedContinuation")
        #expect(checked.declaration.contains(
            "function: Swift.String = #function"))
        #expect(checked.declaration.contains(
            "_Concurrency.CheckedContinuation<T, Swift.Never>"))
        #expect(!checked.declaration.contains("async throws -> sending T"))
        let checkedThrowing = try #require(rows.first {
            $0.name == "withCheckedThrowingContinuation"
        })
        #expect(checkedThrowing.adapterIntrinsic
            == "withCheckedThrowingContinuation")
        #expect(checkedThrowing.declaration.contains(
            "_Concurrency.CheckedContinuation<T, any Swift.Error>"))
        #expect(checkedThrowing.declaration.contains(
            "async throws -> sending T"))
        let unsafe = try #require(rows.first {
            $0.name == "withUnsafeContinuation"
        })
        #expect(unsafe.adapterIntrinsic == "unsupportedUnsafeContinuation")
        #expect(unsafe.declaration.contains("@unsafe public func"))
        #expect(unsafe.declaration.contains(
            "_Concurrency.UnsafeContinuation<T, Swift.Never>"))
        #expect(!unsafe.declaration.contains("async throws -> sending T"))
        let unsafeThrowing = try #require(rows.first {
            $0.name == "withUnsafeThrowingContinuation"
        })
        #expect(unsafeThrowing.adapterIntrinsic
            == "unsupportedUnsafeContinuation")
        #expect(unsafeThrowing.declaration.contains("@unsafe public func"))
        #expect(unsafeThrowing.declaration.contains(
            "_Concurrency.UnsafeContinuation<T, any Swift.Error>"))
        #expect(unsafeThrowing.declaration.contains(
            "async throws -> sending T"))

        let claims = status.interfaceOverrides.filter { expected[$0.id] != nil }
        #expect(claims.count == 4)
        #expect(Set(claims.map(\.id)) == Set(expected.keys))
        let checkedClaim = try #require(claims.first {
            $0.id == checked.id
        })
        #expect(checkedClaim.implementationStatus == .runtimeSupported)
        #expect(checkedClaim.verificationStatus == .nativeParity)
        #expect(checkedClaim.requirementRef
            == "M6/protocol-iteration-streams-and-continuations")
        #expect(checkedClaim.evidenceCaseIDs == [
            "checked-continuation-value-resume",
            "checked-continuation-double-resume",
            "checked-continuation-abandonment",
            "checked-continuation-escaped-token-lifetime",
            "checked-continuation-mainactor-resume",
            "checked-continuation-omitted-isolation",
            "checked-continuation-result-spellings",
            "checked-continuation-source-actor-isolation",
            "checked-continuation-void-resume",
        ])
        #expect(checkedClaim.testNames == [
            "CheckedContinuationRuntimeTests/detachedProducerResumesValueAndClosesRuntimeRecord",
            "CheckedContinuationRuntimeTests/doubleResumeIsFatalAcrossCheckedFormsAndCleansUp",
            "CheckedContinuationRuntimeTests/abandonedTokensWarnAcrossCheckedFormsAndCancelRemainingDrains",
            "CheckedContinuationRuntimeTests/escapedResumedTokensReleaseOwnerGraphAndRuntimeWithoutWarnings",
            "CheckedContinuationRuntimeTests/delayedResumeOwnsCanonicalSuspensionAndExecutor",
            "CheckedContinuationRuntimeTests/omittedIsolationUsesCallerLexicalContextAndCleansUp",
            "CheckedContinuationRuntimeTests/hostCancellationAbortsWaitAndCleansRegistry",
            "CheckedContinuationRuntimeTests/resultResumeSpellingsShareTerminalTransitions",
            "CheckedContinuationRuntimeTests/sourceActorIsolationOwnsBodyReentersAndCleansUp",
            "CheckedContinuationRuntimeTests/voidResumeUsesSameRecordAndCleanup",
            "CompilerPreflightTests/continuationVoidResumeConstraintRejectsNonVoidSuccess",
            "CompilerPreflightTests/continuationResultResumeSpellingsTypecheck",
        ])
        #expect(checkedClaim.gapEvidenceIDs.isEmpty)
        #expect(checkedClaim.notes.contains(
            "explicit isolation: nil and MainActor.shared"))
        #expect(checkedClaim.notes.contains("required resume executor"))
        #expect(checkedClaim.notes.contains(
            "source-actor callers"))
        #expect(checkedClaim.notes.contains("Void resume()"))
        #expect(checkedClaim.notes.contains("Result<T, Never>"))
        #expect(checkedClaim.notes.contains("caller lexical isolation"))
        #expect(checkedClaim.notes.contains("double resume"))
        #expect(checkedClaim.notes.contains("successful-process misuse warning"))
        #expect(checkedClaim.notes.contains("task-local object"))
        #expect(checkedClaim.notes.contains("runtime, session, or interpreter"))
        #expect(checkedClaim.notes.contains("inert"))
        #expect(checkedClaim.notes.contains("runtime-supported with native parity"))

        let checkedThrowingClaim = try #require(claims.first {
            $0.id == checkedThrowing.id
        })
        #expect(checkedThrowingClaim.implementationStatus == .runtimeSupported)
        #expect(checkedThrowingClaim.verificationStatus == .nativeParity)
        #expect(checkedThrowingClaim.requirementRef
            == "M6/protocol-iteration-streams-and-continuations")
        #expect(checkedThrowingClaim.evidenceCaseIDs == [
            "checked-throwing-continuation-value-error",
            "checked-throwing-continuation-double-resume",
            "checked-throwing-continuation-abandonment",
            "checked-continuation-escaped-token-lifetime",
            "checked-throwing-continuation-mainactor-error",
            "checked-throwing-continuation-source-actor-isolation",
            "checked-continuation-omitted-isolation",
            "checked-throwing-continuation-result-resume",
            "checked-continuation-result-spellings",
        ])
        #expect(checkedThrowingClaim.testNames == [
            "CheckedContinuationRuntimeTests/throwingValueAndSourceErrorShareRecordCleanup",
            "CheckedContinuationRuntimeTests/doubleResumeIsFatalAcrossCheckedFormsAndCleansUp",
            "CheckedContinuationRuntimeTests/abandonedTokensWarnAcrossCheckedFormsAndCancelRemainingDrains",
            "CheckedContinuationRuntimeTests/escapedResumedTokensReleaseOwnerGraphAndRuntimeWithoutWarnings",
            "CheckedContinuationRuntimeTests/throwingMainActorErrorRestoresCallerAndCleansUp",
            "CheckedContinuationRuntimeTests/throwingSourceActorIsolationRestoresErrorAndCleansUp",
            "CheckedContinuationRuntimeTests/omittedIsolationUsesCallerLexicalContextAndCleansUp",
            "CheckedContinuationRuntimeTests/resultResumeUsesReturningAndThrowingTransitions",
            "CheckedContinuationRuntimeTests/resultResumeSpellingsShareTerminalTransitions",
            "CompilerPreflightTests/continuationResultResumeRejectsNonResultArgument",
            "CompilerPreflightTests/continuationResultResumeSpellingsTypecheck",
        ])
        #expect(checkedThrowingClaim.gapEvidenceIDs.isEmpty)
        #expect(checkedThrowingClaim.notes.contains("resume(throwing:)"))
        #expect(checkedThrowingClaim.notes.contains("MainActor"))
        #expect(checkedThrowingClaim.notes.contains("source-actor"))
        #expect(checkedThrowingClaim.notes.contains("mailbox"))
        #expect(checkedThrowingClaim.notes.contains("cooperative"))
        #expect(checkedThrowingClaim.notes.contains("Result resume(with:)"))
        #expect(checkedThrowingClaim.notes.contains("Result<T, any Error>"))
        #expect(checkedThrowingClaim.notes.contains("InterpretedThrow"))
        #expect(checkedThrowingClaim.notes.contains("caller lexical isolation"))
        #expect(checkedThrowingClaim.notes.contains("double resume"))
        #expect(checkedThrowingClaim.notes.contains("misuse-warning canary"))
        #expect(checkedThrowingClaim.notes.contains("task-local object"))
        #expect(checkedThrowingClaim.notes.contains(
            "runtime, session, or interpreter"))
        #expect(checkedThrowingClaim.notes.contains("inert"))
        #expect(checkedThrowingClaim.notes.contains(
            "runtime-supported with native parity"))

        let unsafeClaim = try #require(claims.first {
            $0.id == unsafe.id
        })
        #expect(unsafeClaim.implementationStatus == .diagnosedUnsupported)
        #expect(unsafeClaim.verificationStatus == .focusedOnly)
        #expect(unsafeClaim.requirementRef
            == "M6/protocol-iteration-streams-and-continuations")
        #expect(unsafeClaim.evidenceCaseIDs == [
            "unsafe-continuation-fail-closed",
        ])
        #expect(unsafeClaim.testNames == [
            "CompilerPreflightTests/publicContinuationEntryPointsTypecheckForAuthoredRuntimeDisposition",
            "UnsafeContinuationDiagnosticsTests/unsafeContinuationFailsClosedBeforeOwnership",
        ])
        #expect(unsafeClaim.gapEvidenceIDs == [
            "async-sequence-continuation-runtime",
        ])
        #expect(unsafeClaim.notes.contains(
            "unsupportedUnsafeContinuation intrinsic"))
        #expect(unsafeClaim.notes.contains("explicit MainActor isolation"))
        #expect(unsafeClaim.notes.contains("fails closed"))
        #expect(unsafeClaim.notes.contains("before invoking the body"))
        #expect(unsafeClaim.notes.contains("section 14 depth cap"))

        let unsafeThrowingClaim = try #require(claims.first {
            $0.id == unsafeThrowing.id
        })
        #expect(unsafeThrowingClaim.implementationStatus
            == .diagnosedUnsupported)
        #expect(unsafeThrowingClaim.verificationStatus == .focusedOnly)
        #expect(unsafeThrowingClaim.requirementRef
            == "M6/protocol-iteration-streams-and-continuations")
        #expect(unsafeThrowingClaim.evidenceCaseIDs == [
            "unsafe-throwing-continuation-fail-closed",
        ])
        #expect(unsafeThrowingClaim.testNames == [
            "CompilerPreflightTests/publicContinuationEntryPointsTypecheckForAuthoredRuntimeDisposition",
            "UnsafeContinuationDiagnosticsTests/unsafeThrowingContinuationFailsClosedBeforeOwnership",
        ])
        #expect(unsafeThrowingClaim.gapEvidenceIDs == [
            "async-sequence-continuation-runtime",
        ])
        #expect(unsafeThrowingClaim.notes.contains(
            "unsupportedUnsafeContinuation intrinsic"))
        #expect(unsafeThrowingClaim.notes.contains(
            "explicit MainActor isolation"))
        #expect(unsafeThrowingClaim.notes.contains("fails closed"))
        #expect(unsafeThrowingClaim.notes.contains(
            "before invoking the body"))
        #expect(unsafeThrowingClaim.notes.contains("section 14 depth cap"))
    }

    @Test func taskGroupStatePropertiesHaveExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let stateRows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && ($0.name == "isEmpty" || $0.name == "isCancelled")
        }
        let stateIDs = Set(stateRows.map(\.id))
        let stateClaims = status.interfaceOverrides.filter {
            stateIDs.contains($0.id)
        }

        #expect(stateRows.count == 8,
            "the active SDK task-group state denominator changed")
        #expect(Set(stateRows.compactMap(\.container)) == [
            "DiscardingTaskGroup",
            "TaskGroup",
            "ThrowingDiscardingTaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(stateClaims.map(\.id)) == stateIDs,
            "every task-group state property needs an authored disposition")
        #expect(stateClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupCancelAllHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let cancelRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "cancelAll"
        }
        let cancelIDs = Set(cancelRows.map(\.id))
        let cancelClaims = status.interfaceOverrides.filter {
            cancelIDs.contains($0.id)
        }

        #expect(cancelRows.count == 4,
            "the active SDK task-group cancelAll denominator changed")
        #expect(Set(cancelRows.compactMap(\.container)) == [
            "DiscardingTaskGroup",
            "TaskGroup",
            "ThrowingDiscardingTaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(cancelClaims.map(\.id)) == cancelIDs,
            "every task-group cancelAll declaration needs an authored disposition")
        #expect(cancelClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupWaitForAllHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let waitRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "waitForAll"
        }
        let waitIDs = Set(waitRows.map(\.id))
        let waitClaims = status.interfaceOverrides.filter {
            waitIDs.contains($0.id)
        }

        #expect(waitRows.count == 2,
            "the active SDK task-group waitForAll denominator changed")
        #expect(Set(waitRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(waitClaims.map(\.id)) == waitIDs,
            "every task-group waitForAll declaration needs an authored disposition")
        #expect(waitClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupNextResultHasExplicitReviewedDisposition() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let nextResultRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "nextResult"
        }
        let nextResultIDs = Set(nextResultRows.map(\.id))
        let nextResultClaims = status.interfaceOverrides.filter {
            nextResultIDs.contains($0.id)
        }

        #expect(nextResultRows.count == 1,
            "the active SDK task-group nextResult denominator changed")
        #expect(Set(nextResultRows.compactMap(\.container)) == [
            "ThrowingTaskGroup",
        ])
        #expect(Set(nextResultClaims.map(\.id)) == nextResultIDs,
            "the task-group nextResult declaration needs an authored disposition")
        #expect(nextResultClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupSpawnHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let spawnRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "spawn"
        }
        let spawnIDs = Set(spawnRows.map(\.id))
        let spawnClaims = status.interfaceOverrides.filter {
            spawnIDs.contains($0.id)
        }

        #expect(spawnRows.count == 2,
            "the active SDK task-group spawn denominator changed")
        #expect(Set(spawnRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(spawnClaims.map(\.id)) == spawnIDs,
            "every task-group spawn declaration needs an authored disposition")
        #expect(spawnClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupAsyncHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let asyncRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "async"
        }
        let asyncIDs = Set(asyncRows.map(\.id))
        let asyncClaims = status.interfaceOverrides.filter {
            asyncIDs.contains($0.id)
        }

        #expect(asyncRows.count == 2,
            "the active SDK task-group async denominator changed")
        #expect(Set(asyncRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(asyncClaims.map(\.id)) == asyncIDs,
            "every task-group async declaration needs an authored disposition")
        #expect(asyncClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupAsyncUnlessCancelledHasExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let aliasRows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && $0.name == "asyncUnlessCancelled"
        }
        let aliasIDs = Set(aliasRows.map(\.id))
        let aliasClaims = status.interfaceOverrides.filter {
            aliasIDs.contains($0.id)
        }

        #expect(aliasRows.count == 2,
            "the active SDK asyncUnlessCancelled denominator changed")
        #expect(Set(aliasRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(aliasClaims.map(\.id)) == aliasIDs,
            "every asyncUnlessCancelled declaration needs a disposition")
        #expect(aliasClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupSpawnUnlessCancelledHasExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let aliasRows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && $0.name == "spawnUnlessCancelled"
        }
        let aliasIDs = Set(aliasRows.map(\.id))
        let aliasClaims = status.interfaceOverrides.filter {
            aliasIDs.contains($0.id)
        }

        #expect(aliasRows.count == 2,
            "the active SDK spawnUnlessCancelled denominator changed")
        #expect(Set(aliasRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(aliasClaims.map(\.id)) == aliasIDs,
            "every spawnUnlessCancelled declaration needs a disposition")
        #expect(aliasClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupAddHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let addRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "add"
        }
        let addIDs = Set(addRows.map(\.id))
        let addClaims = status.interfaceOverrides.filter {
            addIDs.contains($0.id)
        }

        #expect(addRows.count == 2,
            "the active SDK task-group add denominator changed")
        #expect(Set(addRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(addClaims.map(\.id)) == addIDs,
            "every task-group add declaration needs an authored disposition")
        #expect(addClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupCanonicalAddTaskHasExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let addTaskRows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && $0.name == "addTask"
                && !$0.declaration.contains("name:")
                && !$0.declaration.contains("executorPreference")
        }
        let addTaskIDs = Set(addTaskRows.map(\.id))
        let addTaskClaims = status.interfaceOverrides.filter {
            addTaskIDs.contains($0.id)
        }

        #expect(addTaskRows.count == 4,
            "the active SDK canonical addTask denominator changed")
        #expect(Set(addTaskRows.compactMap(\.container)) == [
            "DiscardingTaskGroup",
            "TaskGroup",
            "ThrowingDiscardingTaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(addTaskRows.allSatisfy {
            $0.declaration.contains("@isolated(any)")
        }, "canonical addTask operation isolation changed")
        #expect(Set(addTaskClaims.map(\.id)) == addTaskIDs,
            "every canonical addTask declaration needs an authored disposition")
        #expect(addTaskClaims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.gapEvidenceIDs == ["remaining-generated-task-group-surface"]
        }, "canonical addTask must not overclaim arbitrary-actor support")
    }

    @Test func taskGroupExecutorPreferenceAddTaskHasExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let rows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && $0.name == "addTask"
                && $0.declaration.contains("executorPreference")
        }
        let expectedIDs: Set<String> = [
            "swift-concurrency-api-v1:70204490d1f1eb798aaa7fc797f86f8d0346591f9d3a9567599c4fa266a115f2",
            "swift-concurrency-api-v1:c879f92586f549f9f163cd2b25d10446301f5da5c57c24b8349132642ded264f",
            "swift-concurrency-api-v1:04e812c711affe7241baab6633e75c7da52b852d78cfc817db011662ba87394b",
            "swift-concurrency-api-v1:dc4fe7d267ec3fcdfb471d4a68118707547ef1cb1d93481735ed15ddee8db942",
            "swift-concurrency-api-v1:b0ddd176b7a816b800bbd45b7b78ed26258d890f8482b06e26b3d7d1a6422515",
            "swift-concurrency-api-v1:0de8c842b4314d07dbefe7d36793703041e6d501fca947f045488e09fccac5fe",
            "swift-concurrency-api-v1:514ef8e7268807c626d9c9e523833f97513a82374d539d3a504c67c47bd48019",
            "swift-concurrency-api-v1:afa72af44f86a812624609ff70f595de47fe32829058340d692e40ae8d04c2ec",
        ]
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 8,
            "the active SDK executor-preference addTask denominator changed")
        #expect(ids == expectedIDs,
            "the active SDK executor-preference addTask identities changed")
        #expect(Set(rows.compactMap(\.container)) == [
            "DiscardingTaskGroup",
            "TaskGroup",
            "ThrowingDiscardingTaskGroup",
            "ThrowingTaskGroup",
        ])
        for container in Set(rows.compactMap(\.container)) {
            #expect(rows.count { $0.container == container } == 2,
                "\(container) should expose named and unnamed addTask rows")
        }
        #expect(rows.count {
            $0.declaration.contains("name: Swift.String?")
        } == 4)
        #expect(rows.count {
            !$0.declaration.contains("name: Swift.String?")
        } == 4)
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == "addTask"
                && $0.declaration.contains(
                    "executorPreference taskExecutor: (any _Concurrency.TaskExecutor)? = nil")
                && $0.declaration.contains("priority:")
                && $0.declaration.contains("@isolated(any)")
        }, "executor-preference addTask interface shape changed")
        #expect(Set(claims.map(\.id)) == ids,
            "every executor-preference addTask row needs an authored disposition")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef == "M4/remaining-task-group-surface"
                && $0.evidenceCaseIDs
                    == ["task-group-executor-preference-nil-add"]
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/nonNilTaskGroupExecutorPreferenceFailsClosed")
                && $0.gapEvidenceIDs
                    == ["remaining-generated-task-group-surface"]
                && $0.notes.contains("explicit-nil")
                && $0.notes.contains("non-nil TaskExecutor")
                && $0.notes.contains("@isolated(any)")
        }, "executor-preference rows must retain executor and actor gaps")
    }

    @Test func taskGroupCanonicalAddTaskUnlessCancelledHasExplicitDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let rows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && $0.name == "addTaskUnlessCancelled"
                && !$0.declaration.contains("name:")
                && !$0.declaration.contains("executorPreference")
        }
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 4,
            "the active SDK canonical addTaskUnlessCancelled denominator changed")
        #expect(Set(rows.compactMap(\.container)) == [
            "DiscardingTaskGroup",
            "TaskGroup",
            "ThrowingDiscardingTaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(rows.allSatisfy {
            $0.declaration.contains("@isolated(any)")
                && $0.declaration.hasSuffix("-> Swift.Bool")
        }, "canonical conditional-add contract changed")
        #expect(Set(claims.map(\.id)) == ids,
            "every canonical conditional-add row needs an authored disposition")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.gapEvidenceIDs == ["remaining-generated-task-group-surface"]
        }, "conditional add must not overclaim arbitrary-actor support")
    }

    @Test func taskGroupExecutorPreferenceAddTaskUnlessCancelledHasExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let rows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && $0.name == "addTaskUnlessCancelled"
                && $0.declaration.contains("executorPreference")
        }
        let expectedIDs: Set<String> = [
            "swift-concurrency-api-v1:7193654c2ce6605a7ef4b65a223a89ee453fcf806fc92a4e7b30f57f54962b3c",
            "swift-concurrency-api-v1:a4cf732124d8ea8052dc1d8023c262cc2ca6df34115cadf32751672349a5b016",
            "swift-concurrency-api-v1:c0908c7c67c1678539f7e6891a6ba354b932f7cc5629e1f230bd507b9f86ec68",
            "swift-concurrency-api-v1:f1a8416d54168393bf82567af4eba2ab8f691334ab27ecac373fb823ad002034",
            "swift-concurrency-api-v1:09b12567828c894ba0ba682092d1734d846502c319f995a3740a15b437e0f8b5",
            "swift-concurrency-api-v1:bf03c66d92e715aba8fa05ce4289bc2ed500578da39417e8a0402970b105919b",
            "swift-concurrency-api-v1:7763873ae30507abe97a6abc23d51a1d4c3deedd9f0dcb0d947ea6ecbab78a53",
            "swift-concurrency-api-v1:ae387c398f7e5addef96035255b387142bed2598b4f154535805e204c29e6813",
        ]
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 8,
            "the active SDK conditional executor-preference denominator changed")
        #expect(ids == expectedIDs,
            "the active SDK conditional executor-preference identities changed")
        #expect(Set(rows.compactMap(\.container)) == [
            "DiscardingTaskGroup",
            "TaskGroup",
            "ThrowingDiscardingTaskGroup",
            "ThrowingTaskGroup",
        ])
        for container in Set(rows.compactMap(\.container)) {
            #expect(rows.count { $0.container == container } == 2,
                "\(container) should expose named and unnamed conditional rows")
        }
        #expect(rows.count {
            $0.declaration.contains("name: Swift.String?")
        } == 4)
        #expect(rows.count {
            !$0.declaration.contains("name: Swift.String?")
        } == 4)
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == "addTaskUnlessCancelled"
                && $0.declaration.contains(
                    "executorPreference taskExecutor: (any _Concurrency.TaskExecutor)? = nil")
                && $0.declaration.contains("priority:")
                && $0.declaration.contains("@isolated(any)")
                && $0.declaration.hasSuffix("-> Swift.Bool")
        }, "conditional executor-preference interface shape changed")
        #expect(Set(claims.map(\.id)) == ids,
            "every conditional executor-preference row needs a disposition")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef == "M4/remaining-task-group-surface"
                && $0.evidenceCaseIDs == [
                    "task-group-executor-preference-nil-add-unless-cancelled",
                ]
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/nonNilConditionalTaskGroupExecutorPreferenceFailsClosed")
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/cancelledConditionalAddSkipsExecutorPreference")
                && $0.gapEvidenceIDs
                    == ["remaining-generated-task-group-surface"]
                && $0.notes.contains("explicit-nil")
                && $0.notes.contains("non-nil TaskExecutor")
                && $0.notes.contains("@isolated(any)")
        }, "conditional rows must retain executor and actor gaps")
    }

    @Test func taskGroupImmediateAddHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let expectedIDsByContainer: [String: Set<String>] = [
            "DiscardingTaskGroup": [
                "swift-concurrency-api-v1:6224211ab41ee0275ffe93f8662fa5c0e0999e7c6a68858ed604208b0aafcf84",
                "swift-concurrency-api-v1:31fa53cd8382fe9d2d7e27f9696dcf7664439085288856147723b003bc4bc4b9",
            ],
            "TaskGroup": [
                "swift-concurrency-api-v1:051a100512d614f5768a06cffe2493a44bb4fd8e627186404eb0fa9edc1537e0",
                "swift-concurrency-api-v1:23abbdf6354a9a77abb062af62b3327c55b7f5518a570bd2bfb6f9eda00724d5",
            ],
            "ThrowingDiscardingTaskGroup": [
                "swift-concurrency-api-v1:374f13d062447dbda0bb8f1a50fbcce663291d1ba2182e7d363da3ebf9fa768a",
                "swift-concurrency-api-v1:e27437346aed95ad921eb3bedca138b8d6d0a9804bc468f81257e604fcd9d3d4",
            ],
            "ThrowingTaskGroup": [
                "swift-concurrency-api-v1:ee75592c5c4944442086b49ff3bd3f85b7cded12db973cbb3f75ac415b29104b",
                "swift-concurrency-api-v1:c349a0b9ddb2ca9af09e001a724a1352504b1df962d026a638cbbf1547e4ae9a",
            ],
        ]
        let expectedNames: Set<String> = [
            "addImmediateTask",
            "addImmediateTaskUnlessCancelled",
        ]
        let rows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && expectedNames.contains($0.name)
        }
        let ids = Set(rows.map(\.id))
        let actualIDsByContainer = Dictionary(grouping: rows) {
            $0.container ?? "<missing>"
        }.mapValues { Set($0.map(\.id)) }
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 8,
            "the active SDK immediate task-group denominator changed")
        #expect(actualIDsByContainer == expectedIDsByContainer,
            "the active SDK immediate task-group identities changed")
        for container in expectedIDsByContainer.keys {
            #expect(Set(rows.filter { $0.container == container }.map(\.name))
                == expectedNames,
                "\(container) should expose both immediate-add operations")
        }
        #expect(rows.allSatisfy {
            $0.adapterIntrinsic == $0.name
                && $0.declaration.contains(
                    "@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)")
                && $0.declaration.contains("name: Swift.String? = nil")
                && $0.declaration.contains(
                    "priority: _Concurrency.TaskPriority? = nil")
                && $0.declaration.contains(
                    "executorPreference taskExecutor: consuming (any _Concurrency.TaskExecutor)? = nil")
                && $0.declaration.contains(
                    "@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any)")
                && $0.declaration.hasSuffix("-> Swift.Bool")
                    == ($0.name == "addImmediateTaskUnlessCancelled")
        }, "immediate task-group interface shape changed")
        #expect(Set(claims.map(\.id)) == ids,
            "every immediate task-group declaration needs an authored disposition")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef == "M4/remaining-task-group-surface"
                && $0.evidenceCaseIDs == ["task-group-immediate-add"]
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/immediateTaskGroupChildCompletesBeforeAddReturns")
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/immediateTaskGroupChildPreservesExecutorAcrossSuspension")
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/synchronouslyThrowingImmediateGroupChildPublishesFailure")
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/preCancelledUnconditionalImmediateChildObservesCancellation")
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/nonNilImmediateTaskGroupExecutorPreferenceFailsClosed")
                && $0.testNames.contains(
                    "TaskGroupSurfaceTests/immediateTaskGroupChildRejectsUnsupportedOperationExecutors")
                && $0.testNames.contains(
                    "ConcurrencyMethodologyTests/taskGroupImmediateAddHasExplicitReviewedDispositions")
                && $0.gapEvidenceIDs
                    == ["remaining-generated-task-group-surface"]
                && $0.notes.contains("explicit-nil")
                && $0.notes.contains("MainActor")
                && $0.notes.contains("non-nil")
                && $0.notes.contains("preference")
                && $0.notes.contains("@isolated(any)")
        }, "immediate rows must retain executor and actor gaps")
        let conditionalClaims = claims.filter { claim in
            rows.first { $0.id == claim.id }?.name
                == "addImmediateTaskUnlessCancelled"
        }
        #expect(conditionalClaims.count == 4)
        #expect(conditionalClaims.allSatisfy {
            $0.testNames.contains(
                "TaskGroupSurfaceTests/cancelledImmediateConditionalAddSkipsExecutorPreference")
                && $0.notes.contains("cancel")
        }, "conditional immediate rows must preserve cancellation ordering evidence")
    }

    @Test func unsafeCurrentTaskSurfaceHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let topLevelRows = inventory.declarations.filter {
            $0.domain == "top-level-function"
                && $0.name == "withUnsafeCurrentTask"
        }
        let memberRows = inventory.declarations.filter {
            $0.domain == "selected-nominal-member"
                && $0.container == "UnsafeCurrentTask"
        }
        let rows = topLevelRows + memberRows
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }
        let expectedTopLevelIDs: Set<String> = [
            "swift-concurrency-api-v1:635f7627d1ccf205c9733f1ca400229cb59a05cbfc81c128e11eafb04c46d75a",
            "swift-concurrency-api-v1:bde627a4e43726d3fa2b742ff780a9db75c50b38631e924469819d073c42c219",
        ]
        let expectedMemberIDs: Set<String> = [
            "swift-concurrency-api-v1:78eae36b8427f8e8809109d2b2d43de9a7bcff463b04c24d78fd32df34c2d1cf",
            "swift-concurrency-api-v1:8887b127db3a8d5643e1b58f287662ec9ab6177b002a031c17c95958c9b79d43",
            "swift-concurrency-api-v1:4718b96d2ea97a4fd27ff85e8760af3adb8bd4017ace873d4cc6a2dfa374b6d0",
            "swift-concurrency-api-v1:f475b4b3d31eaa92a265b77fe81da55ee3cce943b06a809e7d5688aafc592687",
            "swift-concurrency-api-v1:b21dc773880caaea60df8d860d4d6cab956c2bdafcaea609ab0975af9e970bb0",
            "swift-concurrency-api-v1:f1c29904cee2bda5407ad9e247270f7c87ededa91b9bd4a84ad33d7f47f00c95",
            "swift-concurrency-api-v1:04b47d12b7997736e800b486c3483b669f51b8f5e21ba7cfbfaa6626ded3615c",
            "swift-concurrency-api-v1:475ba589dec42bcadc348e92da712c9b86e7fb14b526241a245b042e829d5740",
            "swift-concurrency-api-v1:12802b7fc89d3a829975702ab13bb49374878be460e6ae40ce29a6089fd42a98",
        ]
        let supportedNames: Set<String> = [
            "==", "basePriority", "cancel", "hashValue", "isCancelled",
            "priority",
        ]
        let unsupportedNames: Set<String> = [
            "escalatePriority", "hash", "unownedTaskExecutor",
        ]

        #expect(Set(topLevelRows.map(\.id)) == expectedTopLevelIDs,
            "the active SDK withUnsafeCurrentTask overloads changed")
        #expect(topLevelRows.count == 2)
        #expect(topLevelRows.allSatisfy {
            $0.adapterIntrinsic == "withCurrentTaskCapability"
        })
        #expect(Set(memberRows.map(\.id)) == expectedMemberIDs,
            "the active SDK UnsafeCurrentTask member denominator changed")
        #expect(memberRows.count == 9)
        #expect(Set(memberRows.map(\.name))
            == supportedNames.union(unsupportedNames))
        #expect(Set(claims.map(\.id)) == ids,
            "every UnsafeCurrentTask declaration needs a disposition")

        let topLevelClaims = claims.filter {
            expectedTopLevelIDs.contains($0.id)
        }
        #expect(topLevelClaims.allSatisfy {
            $0.implementationStatus == .runtimeSupported
                && $0.verificationStatus == .nativeParity
                && $0.requirementRef == "M2/unsafe-current-task-capability"
                && $0.evidenceCaseIDs == ["with-unsafe-current-task"]
        })

        let supportedMemberIDs = Set(memberRows.filter {
            supportedNames.contains($0.name)
        }.map(\.id))
        let supportedClaims = claims.filter {
            supportedMemberIDs.contains($0.id)
        }
        #expect(supportedClaims.count == supportedNames.count)
        #expect(supportedClaims.allSatisfy {
            $0.implementationStatus == .runtimeSupported
                && $0.verificationStatus == .nativeParity
                && $0.requirementRef == "M2/unsafe-current-task-capability"
                && $0.evidenceCaseIDs == ["with-unsafe-current-task"]
        })

        let unsupportedMemberIDs = Set(memberRows.filter {
            unsupportedNames.contains($0.name)
        }.map(\.id))
        let unsupportedClaims = claims.filter {
            unsupportedMemberIDs.contains($0.id)
        }
        #expect(unsupportedClaims.count == unsupportedNames.count)
        #expect(memberRows.filter {
            unsupportedNames.contains($0.name)
        }.allSatisfy { $0.adapterIntrinsic == nil })
        #expect(unsupportedClaims.allSatisfy {
            $0.implementationStatus == .diagnosedUnsupported
                && $0.verificationStatus == .focusedOnly
                && $0.requirementRef
                    == "M7/generated-signatures-and-preflight"
                && $0.gapEvidenceIDs
                    == ["generated-concurrency-signatures-and-preflight"]
                && $0.testNames.contains(
                    "UnsafeCurrentTaskRuntimeTests/everyGeneratedUnroutedMemberHasExplicitDiagnostic")
        })
    }

    @Test func taskGroupNamedAddOverloadsHaveExplicitReviewedDispositions()
            throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let expectedNames: Set<String> = [
            "addTask", "addTaskUnlessCancelled",
        ]
        let rows = inventory.declarations.filter {
            $0.domain == "task-group-member"
                && expectedNames.contains($0.name)
                && $0.declaration.contains("name: Swift.String?")
                && !$0.declaration.contains("executorPreference")
        }
        let ids = Set(rows.map(\.id))
        let claims = status.interfaceOverrides.filter { ids.contains($0.id) }

        #expect(rows.count == 8,
            "the active SDK named add-overload denominator changed")
        #expect(Set(rows.compactMap(\.container)) == [
            "DiscardingTaskGroup",
            "TaskGroup",
            "ThrowingDiscardingTaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(rows.map(\.name)) == expectedNames)
        for container in Set(rows.compactMap(\.container)) {
            #expect(rows.count { $0.container == container } == 2,
                "\(container) should expose one named row per operation")
        }
        #expect(rows.allSatisfy {
            $0.declaration.contains("priority:")
                && $0.declaration.contains("@isolated(any)")
        }, "named add-operation shape changed")
        #expect(Set(claims.map(\.id)) == ids,
            "every named add overload needs an authored disposition")
        #expect(claims.allSatisfy {
            $0.implementationStatus == .knownDivergence
                && $0.verificationStatus == .none
                && $0.requirementRef == "M4/remaining-task-group-surface"
                && $0.evidenceCaseIDs.contains("task-group-named-add")
                && $0.gapEvidenceIDs
                    == ["remaining-generated-task-group-surface"]
                && $0.notes.contains("Task.name")
                && $0.notes.contains("@isolated(any)")
        }, "named rows must retain both name and actor-executor gaps")
    }

    @Test func taskGroupMakeAsyncIteratorHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let iteratorRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "makeAsyncIterator"
        }
        let iteratorIDs = Set(iteratorRows.map(\.id))
        let iteratorClaims = status.interfaceOverrides.filter {
            iteratorIDs.contains($0.id)
        }

        #expect(iteratorRows.count == 2,
            "the active SDK task-group makeAsyncIterator denominator changed")
        #expect(Set(iteratorRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(Set(iteratorClaims.map(\.id)) == iteratorIDs,
            "every task-group makeAsyncIterator declaration needs an authored disposition")
        #expect(iteratorClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupIteratorMembersHaveExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let iteratorRows = inventory.declarations.filter {
            $0.domain == "task-group-iterator-member"
        }
        let iteratorIDs = Set(iteratorRows.map(\.id))
        let iteratorClaims = status.interfaceOverrides.filter {
            iteratorIDs.contains($0.id)
        }

        #expect(iteratorRows.count == 6,
            "the active SDK task-group iterator-member denominator changed")
        #expect(Set(iteratorRows.map(\.container)) == [
            "TaskGroup.Iterator",
            "ThrowingTaskGroup.Iterator",
        ])
        #expect(iteratorRows.count { $0.name == "next" } == 4)
        #expect(iteratorRows.count { $0.name == "cancel" } == 2)
        #expect(Set(iteratorClaims.map(\.id)) == iteratorIDs,
            "every task-group iterator declaration needs an authored disposition")
        #expect(iteratorClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func taskGroupNextHasExplicitReviewedDispositions() throws {
        let manifestRoot = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests", isDirectory: true)
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "generated-concurrency-api.json")),
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self,
            from: Data(contentsOf: manifestRoot.appendingPathComponent(
                "concurrency-capability-status.json")),
        )
        let nextRows = inventory.declarations.filter {
            $0.domain == "task-group-member" && $0.name == "next"
        }
        let nextIDs = Set(nextRows.map(\.id))
        let nextClaims = status.interfaceOverrides.filter {
            nextIDs.contains($0.id)
        }

        #expect(nextRows.count == 4,
            "the active SDK task-group next denominator changed")
        #expect(Set(nextRows.compactMap(\.container)) == [
            "TaskGroup",
            "ThrowingTaskGroup",
        ])
        #expect(nextRows.count {
            $0.declaration.contains("@_disfavoredOverload")
        } == 2)
        #expect(nextRows.count {
            $0.declaration.contains("next(isolation:")
        } == 2)
        #expect(Set(nextClaims.map(\.id)) == nextIDs,
            "every task-group next declaration needs an authored disposition")
        #expect(nextClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
    }

    @Test func coveredRequirementCannotDependOnOpenWork() {
        let statuses: [String: AcceptanceRequirementStatus] = [
            "M0/foundation": .open,
            "M1/consumer": .covered,
        ]
        let dependencies = [
            "M0/foundation": [],
            "M1/consumer": ["M0/foundation"],
        ]
        #expect(unreadyCoveredRequirements(
            statuses: statuses, dependencies: dependencies,
        )
            == ["M1/consumer -> M0/foundation"])

        let readyStatuses: [String: AcceptanceRequirementStatus] = [
            "M0/foundation": .covered,
            "M1/consumer": .covered,
        ]
        #expect(unreadyCoveredRequirements(
            statuses: readyStatuses, dependencies: dependencies,
        ).isEmpty)
    }

    @Test func parityShardValidatorProvesExactCoverageAndRejectsDuplicateMarkers() throws {
        let manifestURL = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests/parity-cases.json")
        let cases = try JSONDecoder().decode(
            [AcceptanceParityCase].self, from: Data(contentsOf: manifestURL),
        )
        let runtimeCases = cases.filter { $0.mode == "runtime" }
        let shards = (0 ..< 2).map { shardIndex in
            runtimeCases.enumerated().compactMap { offset, parityCase in
                offset % 2 == shardIndex ? parityCase.id : nil
            }
        }
        let markers = try shards.enumerated().map { shardIndex, caseIDs in
            let repetitions = Dictionary(uniqueKeysWithValues:
                runtimeCases.filter { caseIDs.contains($0.id) }
                    .map { ($0.id, max(1, $0.repetitions)) })
            let payload: [String: Any] = [
                "version": 1,
                "shardIndex": shardIndex,
                "shardCount": shards.count,
                "selectedCount": caseIDs.count,
                "completedCount": caseIDs.count,
                "selectedIDs": caseIDs,
                "completedIDs": caseIDs,
                "selectedRepetitionsByCase": repetitions,
                "completedRepetitionsByCase": repetitions,
                "nativeObservationSHA256ByCase": Dictionary(
                    uniqueKeysWithValues: caseIDs.map { ($0, String(repeating: "0", count: 64)) }),
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys],
            )
            return try "@@concurrency-parity-summary "
                + #require(String(data: data, encoding: .utf8))
        }

        let accepted = try runShardValidator(
            manifestURL: manifestURL,
            logs: markers.map { $0 + "\n" },
        )
        #expect(accepted.status == 0, Comment(rawValue: accepted.standardError))
        #expect(accepted.standardOutput.contains(
            "\"runtimeCaseCount\":\(runtimeCases.count)"))
        #expect(accepted.standardOutput.contains(
            "\"runtimeRepetitionCount\":\(runtimeCases.reduce(0) { $0 + max(1, $1.repetitions) })"))
        #expect(accepted.standardOutput.contains(
            "\"nativeObservationSHA256ByCase\""))

        func rejected(_ logs: [String], containing fragment: String) throws {
            let result = try runShardValidator(
                manifestURL: manifestURL,
                logs: logs.map { $0 + "\n" },
            )
            #expect(result.status != 0)
            #expect(result.standardError.contains(fragment),
                    Comment(rawValue: result.standardError))
        }

        var missingCount = markers
        missingCount[0] = try mutateMarker(markers[0]) {
            $0.removeValue(forKey: "selectedCount")
        }
        try rejected(missingCount, containing: "selectedCount")

        let firstID = try #require(shards[0].first)
        var wrongRepetitions = markers
        wrongRepetitions[0] = try mutateMarker(markers[0]) { payload in
            var repetitions = payload["selectedRepetitionsByCase"]
                as? [String: Any] ?? [:]
            repetitions[firstID] = 999
            payload["selectedRepetitionsByCase"] = repetitions
        }
        try rejected(wrongRepetitions, containing: "repetition counts")

        var missingDigest = markers
        missingDigest[0] = try mutateMarker(markers[0]) { payload in
            var digests = payload["nativeObservationSHA256ByCase"]
                as? [String: Any] ?? [:]
            digests.removeValue(forKey: firstID)
            payload["nativeObservationSHA256ByCase"] = digests
        }
        try rejected(missingDigest, containing: "digest IDs")

        var malformedDigest = markers
        malformedDigest[0] = try mutateMarker(markers[0]) { payload in
            var digests = payload["nativeObservationSHA256ByCase"]
                as? [String: Any] ?? [:]
            digests[firstID] = "NOT-A-SHA256"
            payload["nativeObservationSHA256ByCase"] = digests
        }
        try rejected(malformedDigest, containing: "lowercase SHA-256")

        var incompleteUnion = markers
        incompleteUnion[0] = try mutateMarker(markers[0]) { payload in
            for key in ["selectedIDs", "completedIDs"] {
                var ids = payload[key] as? [String] ?? []
                ids.removeAll { $0 == firstID }
                payload[key] = ids
                payload[key == "selectedIDs" ? "selectedCount" : "completedCount"]
                    = ids.count
            }
            for key in [
                "selectedRepetitionsByCase",
                "completedRepetitionsByCase",
                "nativeObservationSHA256ByCase",
            ] {
                var values = payload[key] as? [String: Any] ?? [:]
                values.removeValue(forKey: firstID)
                payload[key] = values
            }
        }
        try rejected(incompleteUnion, containing: "does not equal runtime manifest")

        let overlapID = try #require(shards[1].first)
        let overlapRepetitions = try max(1, #require(
            runtimeCases.first { $0.id == overlapID }).repetitions)
        var overlapping = markers
        overlapping[0] = try mutateMarker(markers[0]) { payload in
            for key in ["selectedIDs", "completedIDs"] {
                var ids = payload[key] as? [String] ?? []
                ids.append(overlapID)
                payload[key] = ids
                payload[key == "selectedIDs" ? "selectedCount" : "completedCount"]
                    = ids.count
            }
            for key in [
                "selectedRepetitionsByCase",
                "completedRepetitionsByCase",
            ] {
                var values = payload[key] as? [String: Any] ?? [:]
                values[overlapID] = overlapRepetitions
                payload[key] = values
            }
            var digests = payload["nativeObservationSHA256ByCase"]
                as? [String: Any] ?? [:]
            digests[overlapID] = String(repeating: "0", count: 64)
            payload["nativeObservationSHA256ByCase"] = digests
        }
        try rejected(overlapping, containing: "selected by shards")

        let duplicate = try runShardValidator(
            manifestURL: manifestURL,
            logs: [markers.joined(separator: "\n") + "\n" + markers[0] + "\n"],
        )
        #expect(duplicate.status != 0)
        #expect(duplicate.standardError.contains("expected exactly one summary marker"))
    }

    @Test func focusedParityValidatorRequiresTheExactManifestRepetitionTotal() throws {
        let manifestURL = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests/parity-cases.json")
        let cases = try JSONDecoder().decode(
            [AcceptanceParityCase].self, from: Data(contentsOf: manifestURL))
        let runtimeCases = cases.filter { $0.mode == "runtime" }
        let parityCase = try #require(runtimeCases.first {
            $0.id == "protocol-async-sequence-cancellation"
        })
        let caseIndex = try #require(runtimeCases.firstIndex {
            $0.id == parityCase.id
        })
        let total = max(1, parityCase.repetitions)
        let workerCount = min(4, total)
        let base = total / workerCount
        let extra = total % workerCount
        let markers = try (0 ..< workerCount).map { workerIndex in
            let repetitions = base + (workerIndex < extra ? 1 : 0)
            let payload: [String: Any] = [
                "version": 1,
                "shardIndex": caseIndex,
                "shardCount": runtimeCases.count,
                "selectedCount": 1,
                "completedCount": 1,
                "selectedIDs": [parityCase.id],
                "completedIDs": [parityCase.id],
                "selectedRepetitionsByCase": [parityCase.id: repetitions],
                "completedRepetitionsByCase": [parityCase.id: repetitions],
                "nativeObservationSHA256ByCase": [
                    parityCase.id: String(repeating: "0", count: 64),
                ],
            ]
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys])
            return try "@@concurrency-parity-summary "
                + #require(String(data: data, encoding: .utf8)) + "\n"
        }

        let accepted = try runFocusedParityValidator(
            manifestURL: manifestURL,
            caseID: parityCase.id,
            logs: markers)
        #expect(accepted.status == 0,
            Comment(rawValue: accepted.standardError))
        #expect(accepted.standardOutput.contains(
            "\"completedRepetitions\":\(total)"))

        var incomplete = markers
        incomplete[0] = try mutateMarker(markers[0]) { payload in
            for key in [
                "selectedRepetitionsByCase",
                "completedRepetitionsByCase",
            ] {
                var repetitions = payload[key] as? [String: Any] ?? [:]
                repetitions[parityCase.id] = base - 1
                payload[key] = repetitions
            }
        } + "\n"
        let rejectedTotal = try runFocusedParityValidator(
            manifestURL: manifestURL,
            caseID: parityCase.id,
            logs: incomplete)
        #expect(rejectedTotal.status != 0)
        #expect(rejectedTotal.standardError.contains("completed"))

        let duplicate = try runFocusedParityValidator(
            manifestURL: manifestURL,
            caseID: parityCase.id,
            logs: [markers[0] + markers[0]])
        #expect(duplicate.status != 0)
        #expect(duplicate.standardError.contains("expected one summary marker"))
    }

    @Test func gateFingerprintIgnoresUserDiffDrivers() throws {
        let script = try String(
            contentsOf: Self.packageRoot.appendingPathComponent(
                "Scripts/gate.sh"),
            encoding: .utf8)

        #expect(script.contains(
            "git --no-pager diff --no-ext-diff --no-textconv --binary HEAD"),
            Comment(rawValue:
                "the source fingerprint must use built-in Git bytes instead "
                    + "of a user-configured external diff or text conversion"))
    }

    @Test func gateReceiptContractIsSourceBoundAndActionable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-gate-receipt-\(UUID().uuidString)",
                isDirectory: true,
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent("receipt.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Child processes must not inherit the test worker's stdin
        // pipe: under swiftpm-testing-helper's parallel workers the
        // pipe never closes and a child that reads stdin blocks the
        // worker forever (the gate's ~89-test deadlock).
        process.standardInput = FileHandle.nullDevice
        process.arguments = [
            Self.packageRoot.appendingPathComponent("Scripts/gate.sh").path,
        ]
        process.currentDirectoryURL = Self.packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["GATE_JOBS"] = "1"
        environment["GATE_TEST_WORKERS"] = "1"
        environment["GATE_PARITY_TEST_WORKERS"] = "1"
        environment["GATE_EVAL_WORKERS"] = "1"
        environment["GATE_LIVE_WORKERS"] = "1"
        environment["GATE_RECEIPT_PATH"] = receiptURL.path
        environment["GATE_EXPECTED_TOOLCHAIN_FINGERPRINT"] =
            "deliberately-not-the-active-toolchain"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        let receipt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
                as? [String: Any])
        let source = try #require(receipt["source"] as? [String: Any])
        let accounting = try #require(
            source["concurrencyCapabilityAccounting"] as? [String: Any])
        let diagnostics = try #require(
            receipt["diagnostics"] as? [String: Any])
        let configuration = try #require(
            receipt["configuration"] as? [String: Any])
        let effectiveEnvironment = try #require(
            configuration["effectiveEnvironment"] as? [String: Any])
        let inventoryData = try Data(contentsOf:
            Self.packageRoot.appendingPathComponent(
                "Tests/ConcurrencyParity/Manifests/generated-concurrency-api.json"))
        let statusData = try Data(contentsOf:
            Self.packageRoot.appendingPathComponent(
                "Tests/ConcurrencyParity/Manifests/concurrency-capability-status.json"))
        let inventory = try JSONDecoder().decode(
            CapabilityInventoryDocument.self, from: inventoryData,
        )
        let status = try JSONDecoder().decode(
            CapabilityStatusDocument.self, from: statusData)
        let overridesByID = Dictionary(uniqueKeysWithValues:
            status.interfaceOverrides.map { ($0.id, $0.claim) })
        let resolvedClaims = inventory.declarations.map {
            overridesByID[$0.id] ?? status.defaultInterfaceClaim
        }
        let expectedInterfaceImplementationCounts = Dictionary(grouping:
            resolvedClaims, by: { $0.implementationStatus.rawValue })
            .mapValues(\.count)
        let expectedInterfaceVerificationCounts = Dictionary(grouping:
            resolvedClaims, by: { $0.verificationStatus.rawValue })
            .mapValues(\.count)
        let expectedSemanticImplementationCounts = Dictionary(grouping:
            status.semanticCapabilities,
            by: { $0.implementationStatus.rawValue }).mapValues(\.count)
        let expectedSemanticVerificationCounts = Dictionary(grouping:
            status.semanticCapabilities,
            by: { $0.verificationStatus.rawValue }).mapValues(\.count)
        #expect(receipt["result"] as? String == "RED")
        #expect(receipt["schemaVersion"] as? Int == 2)
        #expect(source["commitAtStart"] is String)
        #expect(source["commitAtEnd"] is String)
        #expect(source["worktreeFingerprint"] is String)
        #expect(source["worktreeFingerprintAtEnd"] is String)
        #expect(source["driftDetected"] is Bool)
        #expect(accounting["valid"] as? Bool == true)
        #expect((accounting["errors"] as? [String])?.isEmpty == true)
        #expect(accounting["inventoryPath"] as? String
            == "Tests/ConcurrencyParity/Manifests/generated-concurrency-api.json")
        #expect(accounting["inventoryInputPath"] as? String
            == Self.packageRoot.appendingPathComponent(
                "Tests/ConcurrencyParity/Manifests/generated-concurrency-api.json").path)
        #expect(accounting["inventorySHA256"] as? String
            == sha256(inventoryData))
        #expect(accounting["inventorySchemaVersion"] as? Int
            == inventory.schemaVersion)
        #expect(accounting["inventoryScopeID"] as? String == inventory.scope.id)
        #expect(accounting["declarationCount"] as? Int
            == inventory.summary.declarationCount)
        #expect(accounting["declarationsByDomain"] as? [String: Int]
            == inventory.summary.declarationsByDomain)
        #expect(accounting["adapterRoutedDeclarationCount"] as? Int
            == inventory.summary.adapterRoutedDeclarationCount)
        #expect(accounting["adapterRouteIsSupportEvidence"] as? Bool
            == inventory.scope.adapterRouteIsSupportEvidence)
        #expect(accounting["scopeComplete"] as? Bool == inventory.scope.complete)
        #expect(accounting["statusPath"] as? String
            == "Tests/ConcurrencyParity/Manifests/concurrency-capability-status.json")
        #expect(accounting["statusInputPath"] as? String
            == Self.packageRoot.appendingPathComponent(
                "Tests/ConcurrencyParity/Manifests/concurrency-capability-status.json").path)
        #expect(accounting["statusSHA256"] as? String == sha256(statusData))
        #expect(accounting["statusSchemaVersion"] as? Int
            == status.schemaVersion)
        #expect(accounting["pinnedInventorySHA256"] as? String
            == status.inventorySHA256)
        #expect(accounting["pinMatches"] as? Bool == true)
        #expect(accounting["interfaceOverrideCount"] as? Int
            == status.interfaceOverrides.count)
        #expect(accounting["resolvedInterfaceClaimCount"] as? Int
            == inventory.declarations.count)
        #expect(accounting["reviewedInterfaceClaimCount"] as? Int
            == resolvedClaims.count {
                $0.implementationStatus != .unreviewed
            })
        let implementationCounts = try #require(
            accounting["interfaceImplementationCounts"] as? [String: Int])
        let verificationCounts = try #require(
            accounting["interfaceVerificationCounts"] as? [String: Int])
        #expect(implementationCounts == expectedInterfaceImplementationCounts)
        #expect(verificationCounts == expectedInterfaceVerificationCounts)
        #expect(implementationCounts.values.reduce(0, +)
            == inventory.declarations.count)
        #expect(verificationCounts.values.reduce(0, +)
            == inventory.declarations.count)
        #expect(accounting["semanticCatalogID"] as? String
            == status.semanticCatalog.id)
        #expect(accounting["semanticCatalogVersion"] as? Int
            == status.semanticCatalog.version)
        #expect(accounting["semanticCatalogCompleteForAcceptanceScope"] as? Bool
            == status.semanticCatalog.completeForAcceptanceScope)
        #expect(accounting["semanticCapabilityCount"] as? Int
            == status.semanticCapabilities.count)
        #expect(accounting["semanticImplementationCounts"] as? [String: Int]
            == expectedSemanticImplementationCounts)
        #expect(accounting["semanticVerificationCounts"] as? [String: Int]
            == expectedSemanticVerificationCounts)
        #expect((diagnostics["messages"] as? String)?.contains(
            "toolchain fingerprint mismatch") == true)
        #expect(diagnostics["exitStatuses"] is [String: Any])
        #expect(diagnostics["timeouts"] is [String: Any])
        #expect(configuration["gateLockPolicy"] as? String
            == "exclusive-git-common-dir")
        #expect(configuration["gateLockDirectory"] is String)
        #expect((effectiveEnvironment["GATE_LOCK_DIRECTORY"] as? String)
            == (configuration["gateLockDirectory"] as? String))
    }

    @Test func gateFailsFastBeforeExpensiveStagesAfterTestFailure() throws {
        let script = try String(
            contentsOf: Self.packageRoot.appendingPathComponent(
                "Scripts/gate.sh"),
            encoding: .utf8)
        let failFast = try #require(script.range(of:
            "if (( test_red != 0 )) && [[ \"$continue_after_failure\" != 1 ]]; then"))
        let evaluation = try #require(script.range(of:
            "current_stage=\"evaluation\""))

        #expect(failFast.lowerBound < evaluation.lowerBound)
        #expect(script.contains(
            "evaluation and live stages skipped after test failure"))
        #expect(script.contains(
            "configuration.effectiveEnvironment.GATE_CONTINUE_AFTER_FAILURE"))
    }

    @Test func gateRejectsConcurrentWorktreeRunBeforeBuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-gate-lock-\(UUID().uuidString)",
                isDirectory: true)
        let lockDirectory = directory.appendingPathComponent(
            "closing-gate.lock", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "\(ProcessInfo.processInfo.processIdentifier)\n".write(
            to: lockDirectory.appendingPathComponent("pid"),
            atomically: true,
            encoding: .utf8)
        try "test-owner\n".write(
            to: lockDirectory.appendingPathComponent("worktree"),
            atomically: true,
            encoding: .utf8)
        try "controlled-test\n".write(
            to: lockDirectory.appendingPathComponent("started-at"),
            atomically: true,
            encoding: .utf8)
        let receiptURL = directory.appendingPathComponent("receipt.json")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            Self.packageRoot.appendingPathComponent("Scripts/gate.sh").path,
        ]
        process.currentDirectoryURL = Self.packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["GATE_JOBS"] = "1"
        environment["GATE_TEST_WORKERS"] = "1"
        environment["GATE_PARITY_TEST_WORKERS"] = "1"
        environment["GATE_EVAL_WORKERS"] = "1"
        environment["GATE_LIVE_WORKERS"] = "1"
        environment["GATE_RECEIPT_PATH"] = receiptURL.path
        environment["GATE_LOCK_DIRECTORY"] = lockDirectory.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile()
                + stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        #expect(process.terminationStatus != 0)
        #expect(output.contains("another closing gate is active"))
        #expect(FileManager.default.fileExists(atPath: lockDirectory.path))
        let receipt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
                as? [String: Any])
        let stages = try #require(receipt["stages"] as? [String: Any])
        let build = try #require(stages["build"] as? [String: Any])
        let tests = try #require(stages["tests"] as? [String: Any])
        let evaluation = try #require(stages["evaluation"] as? [String: Any])
        let live = try #require(stages["live"] as? [String: Any])
        #expect(receipt["result"] as? String == "RED")
        #expect(build["status"] as? String == "blocked-concurrent-gate")
        #expect(tests["status"] as? String == "not-run")
        #expect(evaluation["status"] as? String == "not-run")
        #expect(live["status"] as? String == "not-run")
    }

    @Test func gateBlocksInvalidCapabilityAccountingBeforeBuild() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-gate-accounting-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent("receipt.json")
        let statusURL = Self.packageRoot.appendingPathComponent(
            "Tests/ConcurrencyParity/Manifests/concurrency-capability-status.json")
        var status = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: statusURL))
                as? [String: Any])
        status["inventorySHA256"] = String(repeating: "0", count: 64)
        let invalidStatusURL = directory.appendingPathComponent("status.json")
        try JSONSerialization.data(
            withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            .write(to: invalidStatusURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Child processes must not inherit the test worker's stdin
        // pipe: under swiftpm-testing-helper's parallel workers the
        // pipe never closes and a child that reads stdin blocks the
        // worker forever (the gate's ~89-test deadlock).
        process.standardInput = FileHandle.nullDevice
        process.arguments = [
            Self.packageRoot.appendingPathComponent("Scripts/gate.sh").path,
        ]
        process.currentDirectoryURL = Self.packageRoot
        var environment = ProcessInfo.processInfo.environment
        environment["GATE_JOBS"] = "1"
        environment["GATE_TEST_WORKERS"] = "1"
        environment["GATE_PARITY_TEST_WORKERS"] = "1"
        environment["GATE_EVAL_WORKERS"] = "1"
        environment["GATE_LIVE_WORKERS"] = "1"
        environment["GATE_RECEIPT_PATH"] = receiptURL.path
        environment["GATE_CAPABILITY_STATUS_INPUT_PATH"] = invalidStatusURL.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        let receipt = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))
                as? [String: Any])
        let source = try #require(receipt["source"] as? [String: Any])
        let accounting = try #require(
            source["concurrencyCapabilityAccounting"] as? [String: Any])
        let stages = try #require(receipt["stages"] as? [String: Any])
        let build = try #require(stages["build"] as? [String: Any])
        let diagnostics = try #require(
            receipt["diagnostics"] as? [String: Any])
        #expect(receipt["result"] as? String == "RED")
        #expect(accounting["valid"] as? Bool == false)
        #expect(accounting["pinMatches"] as? Bool == false)
        #expect(accounting["statusInputPath"] as? String == invalidStatusURL.path)
        #expect((accounting["errors"] as? [String])?.joined(separator: "\n")
            .contains("inventory pin mismatch") == true)
        #expect(build["status"] as? String == "blocked-source-accounting")
        #expect((diagnostics["messages"] as? String)?.contains(
            "concurrency capability accounting invalid") == true)
    }

    private func loadLedgerRows() throws -> [String: AcceptanceLedgerRow] {
        let ledger = try String(
            contentsOf: Self.packageRoot.appendingPathComponent(
                "Docs/ConcurrencyParity.md"),
            encoding: .utf8,
        )
        var rows: [String: AcceptanceLedgerRow] = [:]
        for line in ledger.split(separator: "\n") {
            let columns = line.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count == 4,
                  let milestoneID = columns[0].split(separator: " ").first,
                  milestoneID.first == "M",
                  Int(milestoneID.dropFirst()) != nil,
                  rows[String(milestoneID)] == nil else { continue }
            rows[String(milestoneID)] = AcceptanceLedgerRow(
                status: columns[1],
                evidence: columns[2],
                remainingWork: columns[3],
            )
        }
        return rows
    }

    private func loadTestFunctionNames() throws -> Set<String> {
        let root = Self.packageRoot.appendingPathComponent(
            "Tests", isDirectory: true,
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }
        let declaration = try NSRegularExpression(
            pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#,
        )
        var names: Set<String> = []
        for item in enumerator {
            guard let url = item as? URL, url.pathExtension == "swift" else {
                continue
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(source.startIndex ..< source.endIndex, in: source)
            declaration.enumerateMatches(in: source, range: range) {
                match, _, _ in
                guard let match,
                      let range = Range(match.range(at: 1), in: source)
                else { return }
                names.insert(String(source[range]))
            }
        }
        return names
    }

    private func runShardValidator(
        manifestURL: URL,
        logs: [String],
    ) throws -> ValidatorProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-shard-validator-\(UUID().uuidString)",
                isDirectory: true,
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURLs = try logs.enumerated().map { index, contents in
            let url = directory.appendingPathComponent("shard-\(index).log")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        // Child processes must not inherit the test worker's stdin
        // pipe: under swiftpm-testing-helper's parallel workers the
        // pipe never closes and a child that reads stdin blocks the
        // worker forever (the gate's ~89-test deadlock).
        process.standardInput = FileHandle.nullDevice
        process.arguments = [
            Self.packageRoot.appendingPathComponent(
                "Scripts/validate-concurrency-parity-summaries.rb").path,
            manifestURL.path,
        ] + logURLs.map(\.path)
        process.currentDirectoryURL = Self.packageRoot
        let stdoutURL = directory.appendingPathComponent("stdout.log")
        let stderrURL = directory.appendingPathComponent("stderr.log")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            try? stdout.close()
            try? stderr.close()
            throw error
        }
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        return ValidatorProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: try Data(contentsOf: stdoutURL), as: UTF8.self),
            standardError: String(
                decoding: try Data(contentsOf: stderrURL), as: UTF8.self),
        )
    }

    private func runFocusedParityValidator(
        manifestURL: URL,
        caseID: String,
        logs: [String]
    ) throws -> ValidatorProcessResult {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "dynamic-swift-focused-parity-validator-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let logURLs = try logs.enumerated().map { index, contents in
            let url = directory.appendingPathComponent("worker-\(index).log")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        // Child processes must not inherit the test worker's stdin
        // pipe: under swiftpm-testing-helper's parallel workers the
        // pipe never closes and a child that reads stdin blocks the
        // worker forever (the gate's ~89-test deadlock).
        process.standardInput = FileHandle.nullDevice
        process.arguments = [
            Self.packageRoot.appendingPathComponent(
                "Scripts/validate-focused-parity-summaries.rb").path,
            manifestURL.path,
            caseID,
        ] + logURLs.map(\.path)
        process.currentDirectoryURL = Self.packageRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ValidatorProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self),
            standardError: String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self))
    }

    private func runCapabilityValidator(
        inventoryURL: URL,
        statusURL: URL,
        acceptanceURL: URL,
        gapsURL: URL,
        parityURL: URL,
        inventoryPath: String,
        statusPath: String
    ) throws -> ValidatorProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        // Child processes must not inherit the test worker's stdin
        // pipe: under swiftpm-testing-helper's parallel workers the
        // pipe never closes and a child that reads stdin blocks the
        // worker forever (the gate's ~89-test deadlock).
        process.standardInput = FileHandle.nullDevice
        process.arguments = [
            Self.packageRoot.appendingPathComponent(
                "Scripts/validate-concurrency-capability-accounting.rb").path,
            inventoryURL.path,
            statusURL.path,
            acceptanceURL.path,
            gapsURL.path,
            parityURL.path,
            inventoryPath,
            statusPath,
        ]
        process.currentDirectoryURL = Self.packageRoot
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ValidatorProcessResult(
            status: process.terminationStatus,
            standardOutput: String(
                decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self),
            standardError: String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self))
    }

    private func mutateMarker(
        _ marker: String,
        _ mutation: (inout [String: Any]) -> Void,
    ) throws -> String {
        let prefix = "@@concurrency-parity-summary "
        let json = String(marker.dropFirst(prefix.count))
        var payload = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any])
        mutation(&payload)
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys],
        )
        return try prefix + #require(String(data: data, encoding: .utf8))
    }

    private func containsDependencyCycle(
        _ milestones: [AcceptanceMilestone],
    ) -> Bool {
        let dependencies = Dictionary(uniqueKeysWithValues:
            milestones.map { ($0.id, $0.dependsOn) })
        var visiting: Set<String> = []
        var visited: Set<String> = []

        func visit(_ id: String) -> Bool {
            if visiting.contains(id) { return true }
            if visited.contains(id) { return false }
            visiting.insert(id)
            for dependency in dependencies[id] ?? [] where visit(dependency) {
                return true
            }
            visiting.remove(id)
            visited.insert(id)
            return false
        }

        return milestones.contains { visit($0.id) }
    }

    private func containsRequirementDependencyCycle(
        _ milestones: [AcceptanceMilestone],
    ) -> Bool {
        let dependencies = Dictionary(uniqueKeysWithValues:
            milestones.flatMap { milestone in
                milestone.requirements.map { requirement in
                    ("\(milestone.id)/\(requirement.id)",
                     requirement.dependsOnRequirements)
                }
            })
        var visiting: Set<String> = []
        var visited: Set<String> = []

        func visit(_ id: String) -> Bool {
            if visiting.contains(id) { return true }
            if visited.contains(id) { return false }
            visiting.insert(id)
            for dependency in dependencies[id] ?? [] where visit(dependency) {
                return true
            }
            visiting.remove(id)
            visited.insert(id)
            return false
        }

        return dependencies.keys.contains { visit($0) }
    }

    private func unreadyCoveredRequirements(
        statuses: [String: AcceptanceRequirementStatus],
        dependencies: [String: [String]],
    ) -> [String] {
        statuses.compactMap { requirement, status -> [String]? in
            guard status == .covered else { return nil }
            let unready = (dependencies[requirement] ?? []).filter {
                statuses[$0] != .covered
            }
            return unready.map { "\(requirement) -> \($0)" }
        }.flatMap(\.self).sorted()
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
