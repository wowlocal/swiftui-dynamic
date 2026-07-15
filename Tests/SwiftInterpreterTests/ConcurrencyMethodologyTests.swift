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
        let testSource = try loadTestSource()

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
        #expect(matrix.executionPlan.currentTail.id == "task-api-closeout")
        #expect(matrix.executionPlan.currentTail.state == "active-closeout")
        #expect(Set(matrix.executionPlan.currentTail.milestoneIDs) == ["M4", "M7"])
        #expect(Set(matrix.executionPlan.currentTail.requirementRefs)
            .isSubset(of: requirementRefs))
        #expect(matrix.executionPlan.currentTail.requirementRefs == [
            "M4/remaining-task-group-surface",
            "M4/group-escape-legality",
            "M7/generated-signatures-and-preflight",
        ])
        #expect(matrix.executionPlan.nextMajorCycle.id
            == "actor-executor-architecture")
        #expect(matrix.executionPlan.nextMajorCycle.state
            == "queued-behind-task-api-closeout")
        #expect(matrix.executionPlan.nextMajorCycle.milestoneID == "M5")
        #expect(Set(matrix.executionPlan.nextMajorCycle.entryRequirementRefs)
            .isSubset(of: requirementRefs))
        #expect(matrix.executionPlan.nextMajorCycle.entryRequirementRefs
            == ["M5/actor-declaration-safety-boundary"])
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
        let nextCycleMilestone = try #require(matrix.milestones.first {
            $0.id == matrix.executionPlan.nextMajorCycle.milestoneID
        })
        #expect(Set(nextCycleMilestone.dependsOn).isSuperset(of:
            Set(matrix.executionPlan.currentTail.milestoneIDs)))
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
                #expect(testSource.contains(
                    "func \(reproductionTest.split(separator: "/").last!)"))
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
            if milestone.status == .complete {
                #expect(milestone.requirements.allSatisfy { $0.status == .covered },
                        "\(milestone.id) is complete without complete coverage")
            }
            if milestone.status == .provisional
                || milestone.status == .partial
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
                    #expect(functionName.map { testSource.contains("func \($0)(") } == true,
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
        let testSource = try loadTestSource()

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
                #expect(testSource.contains("func \(functionName)("),
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
                $0.domain == "task-group-member"
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

        #expect(taskStaticIDs.count == 21,
            "the active SDK Task-static denominator changed")
        #expect(Set(taskStaticClaims.map(\.id)) == taskStaticIDs,
            "every Task-static overload needs an authored disposition")
        #expect(taskStaticClaims.allSatisfy {
            $0.implementationStatus != .unreviewed
        })
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

    private func loadTestSource() throws -> String {
        let root = Self.packageRoot.appendingPathComponent(
            "Tests", isDirectory: true,
        )
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
        ) else { return "" }
        return try enumerator.compactMap { item -> String? in
            guard let url = item as? URL, url.pathExtension == "swift" else {
                return nil
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
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
        process.arguments = [
            Self.packageRoot.appendingPathComponent(
                "Scripts/validate-concurrency-parity-summaries.rb").path,
            manifestURL.path,
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
                as: UTF8.self,
            ),
            standardError: String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self,
            ),
        )
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
