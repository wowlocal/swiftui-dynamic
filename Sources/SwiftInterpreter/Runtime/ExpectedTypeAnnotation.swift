import Foundation

/// The scope a type name was WRITTEN in: the compiler module and file imports
/// of the source that spells it, plus the enclosing declaration.
///
/// A merged program keeps every module's declarations in one flat global
/// environment, so a bare nominal can only be resolved correctly by carrying
/// the visibility of the site that named it. Where that site has no module
/// provenance — snippets, shims, host-authored probes — the fields are nil and
/// lookup keeps its legacy flat behavior.
struct LexicalTypeScope {
    let sourceModuleName: String?
    let sourceImportedModuleNames: Set<String>?
    let owner: AnyObject?

    /// Computed rather than stored: the scope holds a declaration reference,
    /// so a shared instance would be non-Sendable global state.
    static var unscoped: LexicalTypeScope {
        LexicalTypeScope(
            sourceModuleName: nil, sourceImportedModuleNames: nil, owner: nil)
    }

    /// True when the site carries enough provenance for module visibility to
    /// decide a name; otherwise the merged global environment is all there is.
    var hasSourceProvenance: Bool {
        sourceModuleName != nil || sourceImportedModuleNames != nil
    }
}

/// A call-site type annotation together with the scope it was written in.
///
/// The text alone is not enough to resolve a nominal: `let tag: Tag =
/// client.get(endpoint:)` names the `Tag` that module Timeline can see, but
/// the generic parameter it binds is resolved while module NetworkClient's
/// frame is running — and NetworkClient imports neither the module that
/// declares the intended `Tag` nor the one that declares its homonym. Carrying
/// the scope is what makes the annotation mean the same thing at the point it
/// is consumed as it did at the point it was typed.
struct ExpectedTypeAnnotation {
    let text: String
    let scope: LexicalTypeScope

    init(text: String, scope: LexicalTypeScope) {
        self.text = text
        self.scope = scope
    }
}
