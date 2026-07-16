#if os(iOS)
func selectedOperatingSystem() -> String { "iOS" }
#else
func selectedOperatingSystem() -> String {
    let invalid: Int = "wrong operating-system branch"
    fatalError("wrong operating-system branch: \(invalid)")
}
#endif

#if arch(arm64)
func selectedArchitecture() -> String { "arm64" }
#else
func selectedArchitecture() -> String {
    let invalid: Int = "wrong architecture branch"
    fatalError("wrong architecture branch: \(invalid)")
}
#endif

#if DEBUG
func selectedConfiguration() -> String { "DEBUG" }
#else
func selectedConfiguration() -> String {
    let invalid: Int = "wrong configuration branch"
    fatalError("wrong configuration branch: \(invalid)")
}
#endif

#if targetEnvironment(simulator)
func selectedEnvironment() -> String { "simulator" }
#else
func selectedEnvironment() -> String {
    let invalid: Int = "wrong target-environment branch"
    fatalError("wrong target-environment branch: \(invalid)")
}
#endif

#if hasFeature(StrictConcurrency)
func selectedStrictConcurrencyFeature() -> String { "strict-concurrency" }
#else
func selectedStrictConcurrencyFeature() -> String {
    let invalid: Int = "strict concurrency feature was hidden"
    fatalError("wrong feature branch: \(invalid)")
}
#endif

#if hasAttribute(preconcurrency)
func selectedPreconcurrencyAttribute() -> String { "preconcurrency" }
#else
func selectedPreconcurrencyAttribute() -> String {
    let invalid: Int = "preconcurrency attribute was hidden"
    fatalError("wrong attribute branch: \(invalid)")
}
#endif

#if objectFormat(MachO)
func selectedObjectFormat() -> String { "MachO" }
#else
func selectedObjectFormat() -> String {
    let invalid: Int = "MachO object format was hidden"
    fatalError("wrong object-format branch: \(invalid)")
}
#endif

#if _endian(little)
func selectedEndianness() -> String { "little" }
#else
func selectedEndianness() -> String {
    let invalid: Int = "little endian target was hidden"
    fatalError("wrong endian branch: \(invalid)")
}
#endif

#if _runtime(_ObjC)
func selectedRuntime() -> String { "ObjC" }
#else
func selectedRuntime() -> String {
    let invalid: Int = "Objective-C runtime was hidden"
    fatalError("wrong runtime branch: \(invalid)")
}
#endif

#if canImport(SwiftUI)
func selectedAvailableModule() -> String { "SwiftUI" }
#else
func selectedAvailableModule() -> String {
    let invalid: Int = "available SDK module was hidden"
    fatalError("available SDK module was hidden: \(invalid)")
}
#endif

#if canImport(DefinitelyMissingModule)
func selectedMissingModule() -> String {
    let invalid: Int = "missing module was exposed"
    fatalError("missing module was exposed: \(invalid)")
}
#else
func selectedMissingModule() -> String { "missing" }
#endif

#if canImport(SwiftUI, _version: 9999.0)
// SwiftUI has no user module version in this SDK, so native Swift warns that
// the version is ignored and answers from ordinary importability.
func selectedUnavailableModuleVersion() -> String { "version-ignored" }
#else
func selectedUnavailableModuleVersion() -> String {
    let invalid: Int = "native ignored-version behavior was lost"
    fatalError("native ignored-version behavior was lost: \(invalid)")
}
#endif

#if canImport(DefinitelyMissingModule, _version: 1.0)
func selectedMissingModuleVersion() -> String {
    let invalid: Int = "missing versioned module was exposed"
    fatalError("missing versioned module was exposed: \(invalid)")
}
#else
func selectedMissingModuleVersion() -> String { "version-missing" }
#endif

#if swift(>=6.3.3) && swift(<6.3.4)
func selectedSwiftConditionalVersion() -> String { "swift-6.3.3" }
#else
func selectedSwiftConditionalVersion() -> String {
    let invalid: Int = "wrong Swift conditional-compilation version"
    fatalError("wrong Swift version branch: \(invalid)")
}
#endif

#if compiler(>=6.3.3) && compiler(<6.3.4)
func selectedCompilerVersion() -> String { "compiler-6.3.3" }
#else
func selectedCompilerVersion() -> String {
    let invalid: Int = "wrong compiler version"
    fatalError("wrong compiler version branch: \(invalid)")
}
#endif

@MainActor
func selectedExplicitMainActor() -> String { "MainActor" }

// This call is legal only when the target's default isolation is MainActor.
func selectedDefaultIsolation() -> String { selectedExplicitMainActor() }

@available(iOS 18.0, *)
func deploymentFloor() -> String { "iOS18" }

func selectedDeployment() -> String { deploymentFloor() }

let targetConditionProbe = selectedOperatingSystem()
    + "|" + selectedArchitecture()
    + "|" + selectedConfiguration()
    + "|" + selectedEnvironment()
    + "|" + selectedStrictConcurrencyFeature()
    + "|" + selectedPreconcurrencyAttribute()
    + "|" + selectedObjectFormat()
    + "|" + selectedEndianness()
    + "|" + selectedRuntime()
    + "|" + selectedAvailableModule()
    + "|" + selectedMissingModule()
    + "|" + selectedUnavailableModuleVersion()
    + "|" + selectedMissingModuleVersion()
    + "|" + selectedSwiftConditionalVersion()
    + "|" + selectedCompilerVersion()
    + "|" + selectedDefaultIsolation()
    + "|" + selectedDeployment()
