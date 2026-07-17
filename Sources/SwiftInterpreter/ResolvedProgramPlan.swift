import SwiftSyntax

/// One immutable target-specific projection of a parsed program.
///
/// `ParsedProgramMetadata` retains every conditional branch. A session
/// resolves that source exactly once into this capability before it creates
/// mutable runtime symbols. Runtime entries and escaped closures then retain
/// the same object, so later callbacks cannot fall back to whichever build
/// identity or program the interpreter facade most recently prepared.
public nonisolated final class ResolvedProgramPlan: Sendable {
    public nonisolated struct Summary: Sendable, Equatable {
        /// Source items selected by the target-specific top-level plan.
        public let activeTopLevelItemCount: Int
        /// Selected nominal, function, and global declarations.
        public let activePrimaryDeclarationCount: Int
        /// Selected top-level type aliases.
        public let activeTypeAliasCount: Int
        /// Selected top-level extensions.
        public let activeExtensionCount: Int
        /// Every member block indexed in the source, across all top-level
        /// alternatives.
        public let resolvedMemberBlockCount: Int
        /// One target-selected clause per indexed member block. Blocks below
        /// inactive top-level declarations remain indexed but unreachable;
        /// the declaration plan controls their materialization.
        public let resolvedMemberDeclarationCount: Int

        public init(
            activeTopLevelItemCount: Int,
            activePrimaryDeclarationCount: Int,
            activeTypeAliasCount: Int,
            activeExtensionCount: Int,
            resolvedMemberBlockCount: Int,
            resolvedMemberDeclarationCount: Int
        ) {
            self.activeTopLevelItemCount = activeTopLevelItemCount
            self.activePrimaryDeclarationCount =
                activePrimaryDeclarationCount
            self.activeTypeAliasCount = activeTypeAliasCount
            self.activeExtensionCount = activeExtensionCount
            self.resolvedMemberBlockCount = resolvedMemberBlockCount
            self.resolvedMemberDeclarationCount =
                resolvedMemberDeclarationCount
        }
    }

    public let metadata: ParsedProgramMetadata
    public let buildConfiguration: InterpreterBuildConfiguration
    public let summary: Summary

    let declarationPlan: ResolvedDeclarationPlan
    private let memberPlan: ResolvedMemberPlan

    init(
        metadata: ParsedProgramMetadata,
        buildConfiguration: InterpreterBuildConfiguration
    ) {
        self.metadata = metadata
        self.buildConfiguration = buildConfiguration
        declarationPlan = metadata.declarationIndex.resolve(
            conditionHolds: buildConfiguration.ifConfigConditionHolds)
        memberPlan = metadata.memberMetadataIndex.resolve(
            conditionHolds: buildConfiguration.ifConfigConditionHolds)
        summary = Summary(
            activeTopLevelItemCount: declarationPlan.topLevelItems.count,
            activePrimaryDeclarationCount:
                declarationPlan.primaryDeclarations.count,
            activeTypeAliasCount: declarationPlan.typeAliases.count,
            activeExtensionCount:
                declarationPlan.extensionDeclarations.count,
            resolvedMemberBlockCount: memberPlan.memberBlockCount,
            resolvedMemberDeclarationCount:
                memberPlan.resolvedMemberDeclarationCount)
    }

    func memberDeclarations(
        in block: MemberBlockSyntax
    ) -> [ParsedMemberDeclaration]? {
        memberPlan.declarations(in: block)
    }
}
