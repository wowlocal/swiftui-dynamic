import Testing
@testable import SwiftInterpreter

private final class NativeARCLog {
    // Swift 6 deinitializers are nonisolated even in this MainActor-default
    // test target. Every probe in this suite is nevertheless created and
    // released on the main actor, so this is a deliberately single-threaded
    // native oracle rather than shared production state.
    nonisolated(unsafe) var entries: [String] = []
}

private class NativeARCProbe {
    let name: String
    let log: NativeARCLog
    var strong: NativeARCProbe?
    weak var weak: NativeARCProbe?
    var callback: (() -> String)?

    init(_ name: String, log: NativeARCLog) {
        self.name = name
        self.log = log
    }

    deinit {
        log.entries.append(name)
    }

    func strongReader() -> () -> String {
        { self.name }
    }

    func bareMemberReader() -> () -> String {
        { [self] in name }
    }

    func weakReader() -> () -> String {
        { [weak self] in self?.name ?? "nil" }
    }

    func weakAliasReader() -> () -> String {
        { [weak owner = self] in owner?.name ?? "nil" }
    }

    func unownedReader() -> () -> String {
        { [unowned self] in self.name }
    }

    func unusedReader() -> () -> String {
        { "constant" }
    }

    func nestedWeakReaderFactory() -> () -> () -> String {
        { { [weak self] in self?.name ?? "nil" } }
    }

    func installStrongCycle() {
        callback = { self.name }
    }

    func installWeakCycle() {
        callback = { [weak self] in self?.name ?? "nil" }
    }
}

private final class NativeStrongHolder {
    var value: NativeARCProbe?
}

private final class NativeWeakHolder {
    weak var value: NativeARCProbe?
}

private final class NativeUnownedHolder {
    unowned var value: NativeARCProbe

    init(_ value: NativeARCProbe) {
        self.value = value
    }
}

private final class NativeUnsafeUnownedHolder {
    unowned(unsafe) var value: NativeARCProbe

    init(_ value: NativeARCProbe) {
        self.value = value
    }
}

private final class NativeOptionalUnownedHolder {
    unowned var value: NativeARCProbe?

    init(_ value: NativeARCProbe?) {
        self.value = value
    }
}

private enum NativeStaticWeakSlot {
    static weak var value: NativeARCProbe?
}

private enum NativeEnumWeakSlot {
    static weak var value: NativeARCProbe? = nil
}

private enum NativeEnumUnownedSlot {
    static unowned var value: NativeARCProbe? = nil
}

private final class NativeTemporaryARCProbe {}

private func makeNativeTemporaryARCProbe() -> NativeTemporaryARCProbe {
    NativeTemporaryARCProbe()
}

private final class NativeWeakDefaultHolder {
    weak var value: NativeTemporaryARCProbe? = makeNativeTemporaryARCProbe()
}

private final class NativeWeakInstanceReference {
    weak var value: Instance?

    init(_ value: Instance) {
        self.value = value
    }
}

private final class NativeClassInitializedWeakSlot {
    static weak var value: NativeTemporaryARCProbe? = makeNativeTemporaryARCProbe()
}

private enum NativeEnumInitializedWeakSlot {
    static weak var value: NativeTemporaryARCProbe? = makeNativeTemporaryARCProbe()
}

private weak var nativeGlobalWeakSlot: NativeARCProbe?
private weak var nativeInitializedGlobalWeakSlot: NativeTemporaryARCProbe? =
    makeNativeTemporaryARCProbe()

private class NativeARCBase {
    let log: NativeARCLog

    init(log: NativeARCLog) {
        self.log = log
    }

    deinit {
        log.entries.append("base")
    }
}

private final class NativeARCSubclass: NativeARCBase {
    deinit {
        log.entries.append("child")
    }
}

private final class NativeOwnerWithStoredProbe {
    let log: NativeARCLog
    let child: NativeARCProbe

    init(log: NativeARCLog) {
        self.log = log
        self.child = NativeARCProbe("stored", log: log)
    }

    deinit {
        log.entries.append("owner")
    }
}

private final class NativeARCParent {
    let log: NativeARCLog
    var child: NativeARCChild?

    init(log: NativeARCLog) {
        self.log = log
    }

    deinit {
        log.entries.append("parent")
    }
}

private final class NativeARCChild {
    let log: NativeARCLog
    weak var parent: NativeARCParent?

    init(log: NativeARCLog) {
        self.log = log
    }

    deinit {
        log.entries.append("child")
    }
}

private let interpretedARCPrelude = #"""
var events: [String] = []

final class Probe {
    let name: String
    var strong: Probe?
    weak var weak: Probe?
    var callback: (() -> String)?

    init(_ name: String) {
        self.name = name
    }

    deinit {
        events.append(name)
    }

    func strongReader() -> () -> String {
        { self.name }
    }

    func bareMemberReader() -> () -> String {
        { [self] in name }
    }

    func weakReader() -> () -> String {
        { [weak self] in self?.name ?? "nil" }
    }

    func weakAliasReader() -> () -> String {
        { [weak owner = self] in owner?.name ?? "nil" }
    }

    func unownedReader() -> () -> String {
        { [unowned self] in self.name }
    }

    func unusedReader() -> () -> String {
        { "constant" }
    }

    func nestedWeakReaderFactory() -> () -> () -> String {
        { { [weak self] in self?.name ?? "nil" } }
    }

    func installStrongCycle() {
        callback = { self.name }
    }

    func installWeakCycle() {
        callback = { [weak self] in self?.name ?? "nil" }
    }
}

final class StrongHolder {
    var value: Probe?
}

final class WeakHolder {
    weak var value: Probe?
}

final class UnownedHolder {
    unowned var value: Probe

    init(_ value: Probe) {
        self.value = value
    }
}

final class OptionalUnownedHolder {
    unowned var value: Probe?

    init(_ value: Probe?) {
        self.value = value
    }
}

final class StaticWeakSlot {
    static weak var value: Probe?
}

enum EnumWeakSlot {
    static weak var value: Probe? = nil
}

enum EnumUnownedSlot {
    static unowned var value: Probe? = nil
}
"""#

private func evaluateARC(
    _ body: String, lazyTopLevelGlobals: Bool = false
) throws -> String {
    let result = try Interpreter().run(
        source: interpretedARCPrelude + "\n" + body,
        lazyTopLevelGlobals: lazyTopLevelGlobals)
    return result.stringValue ?? result.stringified
}

@Suite("ARC semantics")
struct ARCSemanticsTests {
    @Test
    func explicitMainActorDeinitializerRunsOnFinalRelease() throws {
        let result = try Interpreter().run(source: """
            var observed = "before"
            final class MainOwned {
                @MainActor deinit { observed = "deinit" }
            }
            do {
                _ = MainOwned()
            }
            observed
            """)

        #expect(result.stringValue == "deinit")
    }

    @Test
    func isolatedMainActorDeinitializerRunsOnFinalRelease() throws {
        let result = try Interpreter().run(source: """
            var observed = "before"
            @MainActor final class MainOwned {
                isolated deinit { observed = "deinit" }
            }
            do {
                _ = MainOwned()
            }
            observed
            """)

        #expect(result.stringValue == "deinit")
    }

    @Test
    func mainActorTypealiasDeinitializerRunsOnFinalRelease() throws {
        let result = try Interpreter().run(source: """
            typealias UIActor = MainActor
            var observed = "before"
            final class MainOwned {
                @UIActor deinit { observed = "deinit" }
            }
            do {
                _ = MainOwned()
            }
            observed
            """)

        #expect(result.stringValue == "deinit")
    }

    @Test
    func isolatedSourceActorDeinitializerFailsClosedAtInstantiation() throws {
        do {
            _ = try Interpreter().run(source: """
                actor Worker {
                    isolated deinit {}
                }
                Worker()
                """)
            Issue.record("source-actor isolated deinitializer was admitted")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.line == 2)
            #expect(error.message.contains("isolated deinitializer"))
            #expect(error.message.contains("source-actor executor-owned teardown"))
        }
    }

    @Test
    func executorOwnedDeinitializerDeclarationsDoNotRejectUnusedTypes() throws {
        let result = try Interpreter().run(source: """
            @globalActor actor TeardownActor {
                static let shared = TeardownActor()
            }
            final class MainOwned {
                @MainActor deinit {}
            }
            @MainActor final class IsolatedOwned {
                isolated deinit {}
            }
            final class GlobalOwned {
                @TeardownActor deinit {}
            }
            "collected"
            """)

        #expect(result.stringValue == "collected")
    }

    @Test
    func explicitUserGlobalActorDeinitializerFailsClosedAfterResolution() throws {
        do {
            _ = try Interpreter().run(source: """
                final class GlobalOwned {
                    @TeardownActor deinit {}
                }
                @globalActor actor TeardownActor {
                    static let shared = TeardownActor()
                }
                GlobalOwned()
                """)
            Issue.record("global-actor deinitializer was silently admitted")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.line == 2)
            #expect(error.message.contains("global-actor deinitializer"))
            #expect(error.message.contains("@TeardownActor"))
            #expect(error.message.contains("executor-owned teardown"))
        }
    }

    @Test
    func globalActorTypealiasDeinitializerFailsClosedAfterResolution() throws {
        do {
            _ = try Interpreter().run(source: """
                @globalActor actor TeardownActor {
                    static let shared = TeardownActor()
                }
                typealias TeardownAlias = TeardownActor
                final class GlobalOwned {
                    @TeardownAlias deinit {}
                }
                GlobalOwned()
                """)
            Issue.record("aliased global-actor deinitializer was silently admitted")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.line == 6)
            #expect(error.message.contains("global-actor deinitializer"))
            #expect(error.message.contains("@TeardownAlias"))
            #expect(error.message.contains("executor-owned teardown"))
        }
    }

    @Test
    func qualifiedNestedGlobalActorDeinitializerFailsClosedAfterResolution() throws {
        do {
            _ = try Interpreter().run(source: """
                struct Namespace {
                    @globalActor actor TeardownActor {
                        static let shared = TeardownActor()
                    }
                }
                final class GlobalOwned {
                    @Namespace.TeardownActor deinit {}
                }
                GlobalOwned()
                """)
            Issue.record("qualified global-actor deinitializer was silently admitted")
        } catch let error as RuntimeError {
            #expect(error.fatal)
            #expect(error.line == 7)
            #expect(error.message.contains("global-actor deinitializer"))
            #expect(error.message.contains("@Namespace.TeardownActor"))
            #expect(error.message.contains("executor-owned teardown"))
        }
    }

    @Test
    func enclosingGlobalActorKeepsOrdinaryDeinitializerSupported() throws {
        let result = try Interpreter().run(source: """
            var events: [String] = []
            @globalActor actor TeardownActor {
                static let shared = TeardownActor()
            }
            @TeardownActor final class GlobalOwned {
                deinit { events.append("ordinary") }
            }
            do {
                let value = GlobalOwned()
                _ = value
            }
            events.joined(separator: ",")
            """)

        #expect(result.stringValue == "ordinary")
    }

    @Test func ordinaryActorDeinitializerRemainsSupported() throws {
        let result = try Interpreter().run(source: """
            var events: [String] = []
            actor Worker {
                deinit { events.append("ordinary") }
            }
            do {
                let worker = Worker()
                _ = worker
            }
            events.joined(separator: ",")
            """)

        #expect(result.stringValue == "ordinary")
    }

    @Test func explicitNonisolatedActorDeinitializerRemainsSupported() throws {
        let result = try Interpreter().run(source: """
            var events: [String] = []
            actor Worker {
                nonisolated deinit { events.append("nonisolated") }
            }
            do {
                let worker = Worker()
                _ = worker
            }
            events.joined(separator: ",")
            """)

        #expect(result.stringValue == "nonisolated")
    }

    @Test func weakCaptureAliasBuildsAWeakRuntimeSlot() throws {
        let result = try Interpreter().run(source: interpretedARCPrelude + #"""

        let value = Probe("one")
        value.weakAliasReader()
        """#)
        guard case .closure(let closure) = result,
              let box = closure.captured.box(for: "owner") else {
            Issue.record("weak alias closure did not expose its captured owner slot")
            return
        }
        #expect(box.referenceOwnership == .weak)
        #expect(closure.captured.box(for: "self") == nil)
    }

    @Test func classDeinitializesAtLocalScopeExitLikeNativeSwift() throws {
        let log = NativeARCLog()
        var nativeInside = ""
        do {
            let value = NativeARCProbe("one", log: log)
            nativeInside = value.name
        }
        let native = "\(nativeInside)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var inside = ""
        do {
            let value = Probe("one")
            inside = value.name
        }
        "\(inside)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func assigningNilReleasesTheLastStrongReferenceLikeNativeSwift() throws {
        let log = NativeARCLog()
        var value: NativeARCProbe? = NativeARCProbe("one", log: log)
        let nativeBefore = withExtendedLifetime(value) {
            _ = value?.name
            return log.entries.count
        }
        value = nil
        let native = "\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var value: Probe? = Probe("one")
        let before = events.count
        value = nil
        "\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func strongPropertyRetainsUntilClearedLikeNativeSwift() throws {
        let log = NativeARCLog()
        let holder = NativeStrongHolder()
        do {
            let value = NativeARCProbe("one", log: log)
            holder.value = value
        }
        let nativeBefore = log.entries.joined(separator: ",")
        holder.value = nil
        let native = "\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        let holder = StrongHolder()
        do {
            let value = Probe("one")
            holder.value = value
        }
        let before = events.joined(separator: ",")
        holder.value = nil
        "\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakPropertyZeroesAndDoesNotRetainLikeNativeSwift() throws {
        let log = NativeARCLog()
        let holder = NativeWeakHolder()
        var nativeInside = false
        do {
            let value = NativeARCProbe("one", log: log)
            holder.value = value
            nativeInside = holder.value != nil
        }
        let native = "\(nativeInside)|\(holder.value == nil)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        let holder = WeakHolder()
        var inside = false
        do {
            let value = Probe("one")
            holder.value = value
            inside = holder.value != nil
        }
        "\(inside)|\(holder.value == nil)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakLocalVariableZeroesLikeNativeSwift() throws {
        let log = NativeARCLog()
        func nativeOutcome() -> String {
            weak var observed: NativeARCProbe?
            do {
                let value = NativeARCProbe("one", log: log)
                observed = value
            }
            return "\(observed == nil)|\(log.entries.joined(separator: ","))"
        }
        let native = nativeOutcome()

        let interpreted = try evaluateARC(#"""
        func outcome() -> String {
            weak var observed: Probe?
            do {
                let value = Probe("one")
                observed = value
            }
            return "\(observed == nil)|\(events.joined(separator: ","))"
        }
        outcome()
        """#)

        #expect(interpreted == native)
    }

    @Test func strongSelfCaptureRetainsUntilClosureReleaseLikeNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        do {
            let value = NativeARCProbe("one", log: log)
            reader = value.strongReader()
        }
        let nativeRead = reader!()
        let nativeBefore = log.entries.joined(separator: ",")
        reader = nil
        let native = "\(nativeRead)|\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let value = Probe("one")
            reader = value.strongReader()
        }
        let read = reader!()
        let before = events.joined(separator: ",")
        reader = nil
        "\(read)|\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakSelfCaptureDoesNotRetainAndReadsNilLikeNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        do {
            let value = NativeARCProbe("one", log: log)
            reader = value.weakReader()
        }
        let native = "\(reader!())|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let value = Probe("one")
            reader = value.weakReader()
        }
        "\(reader!())|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakCaptureAliasMatchesNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        do {
            let value = NativeARCProbe("one", log: log)
            reader = value.weakAliasReader()
        }
        let native = "\(reader!())|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let value = Probe("one")
            reader = value.weakAliasReader()
        }
        "\(reader!())|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func closureThatDoesNotUseSelfDoesNotRetainItLikeNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        do {
            let value = NativeARCProbe("one", log: log)
            reader = value.unusedReader()
        }
        let native = "\(reader!())|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let value = Probe("one")
            reader = value.unusedReader()
        }
        "\(reader!())|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func outerClosureRetainsSelfNeededByNestedWeakCaptureLikeNativeSwift() throws {
        let log = NativeARCLog()
        var factory: (() -> () -> String)?
        do {
            let value = NativeARCProbe("one", log: log)
            factory = value.nestedWeakReaderFactory()
        }
        let nativeBefore = log.entries.joined(separator: ",")
        let nativeReader = factory!()
        factory = nil
        let native = "\(nativeBefore)|\(log.entries.joined(separator: ","))|\(nativeReader())"

        let interpreted = try evaluateARC(#"""
        var factory: (() -> () -> String)?
        do {
            let value = Probe("one")
            factory = value.nestedWeakReaderFactory()
        }
        let before = events.joined(separator: ",")
        let reader = factory!()
        factory = nil
        "\(before)|\(events.joined(separator: ","))|\(reader())"
        """#)

        #expect(interpreted == native)
    }

    @Test func explicitStrongCaptureRetainsLikeNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        do {
            let value = NativeARCProbe("one", log: log)
            reader = { [owner = value] in owner.name }
        }
        let nativeRead = reader!()
        let nativeBefore = log.entries.joined(separator: ",")
        reader = nil
        let native = "\(nativeRead)|\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let value = Probe("one")
            reader = { [owner = value] in owner.name }
        }
        let read = reader!()
        let before = events.joined(separator: ",")
        reader = nil
        "\(read)|\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func captureEnvironmentDoesNotRetainUnreferencedLocalsLikeNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        do {
            let owner = NativeARCProbe("owner", log: log)
            let unrelated = NativeARCProbe("unrelated", log: log)
            reader = { [weak owner] in owner?.name ?? "nil" }
            _ = unrelated.name
        }
        let native = "\(reader!())|\(log.entries.sorted().joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let owner = Probe("owner")
            let unrelated = Probe("unrelated")
            reader = { [weak owner] in owner?.name ?? "nil" }
            _ = unrelated.name
        }
        "\(reader!())|\(events.sorted().joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func implicitMutableCaptureStillSharesItsBoxLikeNativeSwift() throws {
        var nativeReader: (() -> String)?
        do {
            var number = 1
            nativeReader = { String(number) }
            number = 2
        }
        let native = nativeReader!()

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            var number = 1
            reader = { String(number) }
            number = 2
        }
        reader!()
        """#)

        #expect(interpreted == native)
    }

    @Test func bareMemberReferenceCapturesSelfStronglyLikeNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        do {
            let value = NativeARCProbe("one", log: log)
            reader = value.bareMemberReader()
        }
        let nativeRead = reader!()
        let nativeBefore = log.entries.joined(separator: ",")
        reader = nil
        let native = "\(nativeRead)|\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let value = Probe("one")
            reader = value.bareMemberReader()
        }
        let read = reader!()
        let before = events.joined(separator: ",")
        reader = nil
        "\(read)|\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func unownedPropertyDoesNotRetainItsTargetLikeNativeSwift() throws {
        let log = NativeARCLog()
        var holder: NativeUnownedHolder?
        var nativeInside = ""
        do {
            let value = NativeARCProbe("one", log: log)
            holder = NativeUnownedHolder(value)
            nativeInside = holder!.value.name
        }
        _ = holder
        let native = "\(nativeInside)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var holder: UnownedHolder?
        var inside = ""
        do {
            let value = Probe("one")
            holder = UnownedHolder(value)
            inside = holder!.value.name
        }
        _ = holder
        "\(inside)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    /// Native Swift 6 strict-concurrency probe: the caller's strong local
    /// keeps an argument alive while a constructed root stores it `unowned`.
    /// `instantiateRoot` is the synthetic caller and must provide that owner
    /// for exactly the lifetime of the synthesized root value.
    @Test func synthesizedRootCallerOwnsUnownedArgumentsForRootLifetime() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        final class Dependency {
            let value = "alive"
        }

        struct Root {
            unowned let dependency: Dependency

            func read() -> String {
                dependency.value
            }
        }
        """)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "Root" })
        guard case .instance(let root) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("synthetic Root did not instantiate")
            return
        }

        let value = try interpreter.callMethod(
            named: "read", on: root, arguments: [])
        #expect(value.stringValue == "alive")
    }

    /// Imported class declarations are absent from a merged source image.
    /// Their synthesized marker must still have reference identity when the
    /// compiled property type is `unowned`; otherwise host-value boxing makes
    /// the weak target disappear before the root's first body evaluation.
    @Test func synthesizedRootOwnsOpaqueImportedUnownedArguments() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: """
        struct Root {
            unowned let dependency: ImportedDependency

            func touch() {
                _ = dependency.isReady
            }
        }
        """, lazyTopLevelGlobals: true)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "Root" })
        guard case .instance(let root) = try interpreter.instantiateRoot(symbol) else {
            Issue.record("synthetic Root did not instantiate")
            return
        }

        _ = try interpreter.callMethod(named: "touch", on: root, arguments: [])
    }

    @Test func unownedCaptureDoesNotRetainButWorksWhileAliveLikeNativeSwift() throws {
        let log = NativeARCLog()
        var reader: (() -> String)?
        var nativeInside = ""
        do {
            let value = NativeARCProbe("one", log: log)
            reader = value.unownedReader()
            nativeInside = reader!()
        }
        _ = reader
        let native = "\(nativeInside)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        var inside = ""
        do {
            let value = Probe("one")
            reader = value.unownedReader()
            inside = reader!()
        }
        _ = reader
        "\(inside)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func unsafeUnownedPropertyDoesNotRetainLikeNativeSwift() throws {
        let log = NativeARCLog()
        var holder: NativeUnsafeUnownedHolder?
        do {
            let value = NativeARCProbe("one", log: log)
            holder = NativeUnsafeUnownedHolder(value)
            _ = holder!.value.name
        }
        _ = holder
        let native = log.entries.joined(separator: ",")

        let interpreted = try evaluateARC(#"""
        final class UnsafeHolder {
            unowned(unsafe) var value: Probe
            init(_ value: Probe) { self.value = value }
        }
        var holder: UnsafeHolder?
        do {
            let value = Probe("one")
            holder = UnsafeHolder(value)
            _ = holder!.value.name
        }
        _ = holder
        events.joined(separator: ",")
        """#)

        #expect(interpreted == native)
    }

    @Test func deadUnownedPropertyRaisesAnInterpreterTrap() throws {
        #expect(throws: RuntimeError.self) {
            _ = try Interpreter().run(source: interpretedARCPrelude + #"""

            var holder: UnownedHolder?
            do {
                let value = Probe("one")
                holder = UnownedHolder(value)
            }
            holder!.value.name
            """#)
        }
    }

    @Test func deadUnownedCaptureRaisesAnInterpreterTrap() throws {
        #expect(throws: RuntimeError.self) {
            _ = try Interpreter().run(source: interpretedARCPrelude + #"""

            var reader: (() -> String)?
            do {
                let value = Probe("one")
                reader = value.unownedReader()
            }
            reader!()
            """#)
        }
    }

    @Test func manualAndAutomaticDeinitializationIsIdempotent() throws {
        let interpreter = Interpreter()
        _ = try interpreter.run(source: #"""
        var events: [String] = []
        final class Once {
            deinit { events.append("once") }
        }
        """#)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "Once" })
        do {
            var value: RuntimeValue? = try interpreter.instantiateRoot(symbol)
            if case .instance(let instance)? = value {
                interpreter.runDeinitializer(on: instance)
            }
            value = nil
        }
        let events = try interpreter.run(source: "events.joined(separator: \",\")")
        #expect(events.stringValue == "once")
    }

    @Test func subclassDeinitializersRunBeforeSuperclassLikeNativeSwift() throws {
        let log = NativeARCLog()
        do {
            let value = NativeARCSubclass(log: log)
            _ = value.log
        }
        let native = log.entries.joined(separator: ",")

        let interpreted = try evaluateARC(#"""
        class Base {
            deinit { events.append("base") }
        }
        final class Child: Base {
            deinit { events.append("child") }
        }
        do {
            let value = Child()
            _ = value
        }
        events.joined(separator: ",")
        """#)

        #expect(interpreted == native)
    }

    @Test func deinitBodyRunsBeforeStoredPropertiesReleaseLikeNativeSwift() throws {
        let log = NativeARCLog()
        do {
            let value = NativeOwnerWithStoredProbe(log: log)
            _ = value.child.name
        }
        let native = log.entries.joined(separator: ",")

        let interpreted = try evaluateARC(#"""
        final class Owner {
            let child = Probe("stored")
            deinit { events.append("owner") }
        }
        do {
            let value = Owner()
            _ = value.child.name
        }
        events.joined(separator: ",")
        """#)

        #expect(interpreted == native)
    }

    @Test func weakBackReferenceBreaksParentChildCycleLikeNativeSwift() throws {
        let log = NativeARCLog()
        do {
            let parent = NativeARCParent(log: log)
            let child = NativeARCChild(log: log)
            parent.child = child
            child.parent = parent
        }
        let native = log.entries.joined(separator: ",")

        let interpreted = try evaluateARC(#"""
        final class Parent {
            var child: Child?
            deinit { events.append("parent") }
        }
        final class Child {
            weak var parent: Parent?
            deinit { events.append("child") }
        }
        do {
            let parent = Parent()
            let child = Child()
            parent.child = child
            child.parent = parent
        }
        events.joined(separator: ",")
        """#)

        #expect(interpreted == native)
    }

    @Test func strongClosureCyclePersistsUntilBrokenLikeNativeSwift() throws {
        let log = NativeARCLog()
        let observer = NativeWeakHolder()
        var value: NativeARCProbe? = NativeARCProbe("one", log: log)
        value!.installStrongCycle()
        observer.value = value
        value = nil
        let nativeRetained = observer.value != nil
        observer.value!.callback = nil
        let nativeReleased = observer.value == nil
        let native = "\(nativeRetained)|\(nativeReleased)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        let observer = WeakHolder()
        var value: Probe? = Probe("one")
        value!.installStrongCycle()
        observer.value = value
        value = nil
        let retained = observer.value != nil
        observer.value!.callback = nil
        let released = observer.value == nil
        "\(retained)|\(released)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakSelfClosureBreaksCycleLikeNativeSwift() throws {
        let log = NativeARCLog()
        let observer = NativeWeakHolder()
        var value: NativeARCProbe? = NativeARCProbe("one", log: log)
        value!.installWeakCycle()
        observer.value = value
        value = nil
        let native = "\(observer.value == nil)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        let observer = WeakHolder()
        var value: Probe? = Probe("one")
        value!.installWeakCycle()
        observer.value = value
        value = nil
        "\(observer.value == nil)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func arrayRetainsElementsUntilRemovalLikeNativeSwift() throws {
        let log = NativeARCLog()
        var values: [NativeARCProbe] = []
        do {
            let value = NativeARCProbe("one", log: log)
            values.append(value)
        }
        let nativeBefore = withExtendedLifetime(values) {
            log.entries.joined(separator: ",")
        }
        values.removeAll()
        let native = "\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var values: [Probe] = []
        do {
            let value = Probe("one")
            values.append(value)
        }
        let before = events.joined(separator: ",")
        values.removeAll()
        "\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func dictionaryRetainsValuesUntilRemovalLikeNativeSwift() throws {
        let log = NativeARCLog()
        var values: [String: NativeARCProbe] = [:]
        do {
            let value = NativeARCProbe("one", log: log)
            values["key"] = value
        }
        let nativeBefore = withExtendedLifetime(values) {
            log.entries.joined(separator: ",")
        }
        values = [:]
        let native = "\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var values: [String: Probe] = [:]
        do {
            let value = Probe("one")
            values["key"] = value
        }
        let before = events.joined(separator: ",")
        values = [:]
        "\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func replacingStrongPropertyReleasesOldValueLikeNativeSwift() throws {
        let log = NativeARCLog()
        let holder = NativeStrongHolder()
        holder.value = NativeARCProbe("first", log: log)
        holder.value = NativeARCProbe("second", log: log)
        let nativeAfterReplacement = log.entries.joined(separator: ",")
        holder.value = nil
        let native = "\(nativeAfterReplacement)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        let holder = StrongHolder()
        holder.value = Probe("first")
        holder.value = Probe("second")
        let afterReplacement = events.joined(separator: ",")
        holder.value = nil
        "\(afterReplacement)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func explicitCaptureListSnapshotsMutableValueLikeNativeSwift() throws {
        var number = 1
        let nativeReader = { [number] in String(number) }
        number = 2
        let native = nativeReader()

        let interpreted = try evaluateARC(#"""
        var number = 1
        let reader = { [number] in String(number) }
        number = 2
        reader()
        """#)

        #expect(interpreted == native)
    }

    @Test func nestedBlockShadowDoesNotSuppressOuterCaptureLikeNativeSwift() throws {
        let log = NativeARCLog()
        var nativeReader: (() -> String)?
        do {
            let value = NativeARCProbe("outer", log: log)
            nativeReader = {
                do {
                    let value = "shadow"
                    _ = value
                }
                return value.name
            }
        }
        let nativeBefore = log.entries.joined(separator: ",")
        let nativeRead = nativeReader!()
        nativeReader = nil
        let native = "\(nativeRead)|\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: (() -> String)?
        do {
            let value = Probe("outer")
            reader = {
                do {
                    let value = "shadow"
                    _ = value
                }
                return value.name
            }
        }
        let before = events.joined(separator: ",")
        let read = reader!()
        reader = nil
        "\(read)|\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakCaptureTransitionsFromLiveToNilLikeNativeSwift() throws {
        let log = NativeARCLog()
        var nativeValue: NativeARCProbe? = NativeARCProbe("one", log: log)
        let nativeReader = { [weak nativeValue] in nativeValue?.name ?? "nil" }
        let nativeLive = nativeReader()
        nativeValue = nil
        let native = "\(nativeLive)|\(nativeReader())|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var value: Probe? = Probe("one")
        let reader = { [weak value] in value?.name ?? "nil" }
        let live = reader()
        value = nil
        "\(live)|\(reader())|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakPropertyCanBeReassignedWithoutRetainingEitherTargetLikeNativeSwift() throws {
        let log = NativeARCLog()
        let holder = NativeWeakHolder()
        var first: NativeARCProbe? = NativeARCProbe("first", log: log)
        var second: NativeARCProbe? = NativeARCProbe("second", log: log)
        holder.value = first
        first = nil
        let nativeAfterFirst = holder.value == nil
        holder.value = second
        let nativeWhileSecondLives = holder.value?.name ?? "nil"
        second = nil
        let native = "\(nativeAfterFirst)|\(nativeWhileSecondLives)|\(holder.value == nil)|\(log.entries.sorted().joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        let holder = WeakHolder()
        var first: Probe? = Probe("first")
        var second: Probe? = Probe("second")
        holder.value = first
        first = nil
        let afterFirst = holder.value == nil
        holder.value = second
        let whileSecondLives = holder.value?.name ?? "nil"
        second = nil
        "\(afterFirst)|\(whileSecondLives)|\(holder.value == nil)|\(events.sorted().joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func tupleRetainsReferenceUntilElementIsClearedLikeNativeSwift() throws {
        let log = NativeARCLog()
        var tuple: (NativeARCProbe?, Int) = (nil, 0)
        do {
            let value = NativeARCProbe("one", log: log)
            tuple.0 = value
        }
        let nativeHeld = tuple.0 != nil
        let nativeBefore = log.entries.joined(separator: ",")
        tuple.0 = nil
        let native = "\(nativeHeld)|\(nativeBefore)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var tuple: (Probe?, Int) = (nil, 0)
        do {
            let value = Probe("one")
            tuple.0 = value
        }
        let held = tuple.0 != nil
        let before = events.joined(separator: ",")
        tuple.0 = nil
        "\(held)|\(before)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func replacingClosureReleasesItsPreviousCaptureLikeNativeSwift() throws {
        let log = NativeARCLog()
        var nativeReader: () -> String = { "empty" }
        do {
            let value = NativeARCProbe("first", log: log)
            nativeReader = { value.name }
        }
        let nativeBefore = log.entries.joined(separator: ",")
        nativeReader = { "replacement" }
        let native = "\(nativeBefore)|\(nativeReader())|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var reader: () -> String = { "empty" }
        do {
            let value = Probe("first")
            reader = { value.name }
        }
        let before = events.joined(separator: ",")
        reader = { "replacement" }
        "\(before)|\(reader())|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func optionalUnownedStorageAcceptsExplicitNilWithoutRetainingLikeNativeSwift() throws {
        let log = NativeARCLog()
        var nativeHolder: NativeOptionalUnownedHolder?
        do {
            let value = NativeARCProbe("one", log: log)
            nativeHolder = NativeOptionalUnownedHolder(value)
            _ = nativeHolder!.value?.name
            nativeHolder!.value = nil
        }
        let native = "\(nativeHolder!.value == nil)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var holder: OptionalUnownedHolder?
        do {
            let value = Probe("one")
            holder = OptionalUnownedHolder(value)
            _ = holder!.value?.name
            holder!.value = nil
        }
        "\(holder!.value == nil)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func staticWeakStorageZeroesLikeNativeSwift() throws {
        NativeStaticWeakSlot.value = nil
        let log = NativeARCLog()
        var nativeInside = false
        do {
            let value = NativeARCProbe("one", log: log)
            NativeStaticWeakSlot.value = value
            nativeInside = NativeStaticWeakSlot.value != nil
        }
        let native = "\(nativeInside)|\(NativeStaticWeakSlot.value == nil)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var inside = false
        do {
            let value = Probe("one")
            StaticWeakSlot.value = value
            inside = StaticWeakSlot.value != nil
        }
        "\(inside)|\(StaticWeakSlot.value == nil)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func globalWeakStorageZeroesLikeCompiledSwift() throws {
        nativeGlobalWeakSlot = nil
        let log = NativeARCLog()
        var nativeInside = false
        do {
            let value = NativeARCProbe("one", log: log)
            nativeGlobalWeakSlot = value
            nativeInside = nativeGlobalWeakSlot != nil
        }
        let native = "\(nativeInside)|\(nativeGlobalWeakSlot == nil)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        weak var globalWeak: Probe?
        var inside = false
        do {
            let value = Probe("one")
            globalWeak = value
            inside = globalWeak != nil
        }
        "\(inside)|\(globalWeak == nil)|\(events.joined(separator: ","))"
        """#, lazyTopLevelGlobals: true)

        #expect(interpreted == native)
    }

    @Test func earlyReturnReleasesLocalsBeforeCallerContinuesLikeNativeSwift() throws {
        let log = NativeARCLog()
        func nativeName() -> String {
            let value = NativeARCProbe("one", log: log)
            return value.name
        }
        let nativeNameValue = nativeName()
        let native = "\(nativeNameValue)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        func name() -> String {
            let value = Probe("one")
            return value.name
        }
        let result = name()
        "\(result)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func enumStaticWeakStorageZeroesLikeNativeSwift() throws {
        NativeEnumWeakSlot.value = nil
        let log = NativeARCLog()
        var nativeInside = false
        do {
            let value = NativeARCProbe("one", log: log)
            NativeEnumWeakSlot.value = value
            nativeInside = NativeEnumWeakSlot.value != nil
        }
        let native = "\(nativeInside)|\(NativeEnumWeakSlot.value == nil)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var inside = false
        do {
            let value = Probe("one")
            EnumWeakSlot.value = value
            inside = EnumWeakSlot.value != nil
        }
        "\(inside)|\(EnumWeakSlot.value == nil)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func enumStaticOptionalUnownedCanBeClearedLikeNativeSwift() throws {
        NativeEnumUnownedSlot.value = nil
        let log = NativeARCLog()
        var nativeRead = ""
        do {
            let value = NativeARCProbe("one", log: log)
            NativeEnumUnownedSlot.value = value
            nativeRead = NativeEnumUnownedSlot.value?.name ?? "nil"
            NativeEnumUnownedSlot.value = nil
        }
        let native = "\(nativeRead)|\(NativeEnumUnownedSlot.value == nil)|\(log.entries.joined(separator: ","))"

        let interpreted = try evaluateARC(#"""
        var read = ""
        do {
            let value = Probe("one")
            EnumUnownedSlot.value = value
            read = EnumUnownedSlot.value?.name ?? "nil"
            EnumUnownedSlot.value = nil
        }
        "\(read)|\(EnumUnownedSlot.value == nil)|\(events.joined(separator: ","))"
        """#)

        #expect(interpreted == native)
    }

    @Test func weakInstanceDefaultDropsTemporaryLikeNativeSwift() throws {
        let native = String(NativeWeakDefaultHolder().value == nil)

        let interpreted = try evaluateARC(#"""
        func makeTemporary() -> Probe { Probe("temporary") }
        final class WeakDefaultHolder {
            weak var value: Probe? = makeTemporary()
        }
        String(WeakDefaultHolder().value == nil)
        """#)

        #expect(interpreted == native)
    }

    @Test func classWeakStaticInitializerDropsTemporaryLikeNativeSwift() throws {
        let native = String(NativeClassInitializedWeakSlot.value == nil)

        let interpreted = try evaluateARC(#"""
        func makeTemporary() -> Probe { Probe("temporary") }
        final class InitializedWeakSlot {
            static weak var value: Probe? = makeTemporary()
        }
        String(InitializedWeakSlot.value == nil)
        """#)

        #expect(interpreted == native)
    }

    @Test func enumWeakStaticInitializerDropsTemporaryLikeNativeSwift() throws {
        let native = String(NativeEnumInitializedWeakSlot.value == nil)

        let interpreted = try evaluateARC(#"""
        func makeTemporary() -> Probe { Probe("temporary") }
        enum InitializedWeakSlot {
            static weak var value: Probe? = makeTemporary()
        }
        String(InitializedWeakSlot.value == nil)
        """#)

        #expect(interpreted == native)
    }

    @Test func weakGlobalInitializerDropsTemporaryLikeCompiledSwift() throws {
        let native = String(nativeInitializedGlobalWeakSlot == nil)

        let interpreted = try evaluateARC(#"""
        func makeTemporary() -> Probe { Probe("temporary") }
        weak var initializedGlobal: Probe? = makeTemporary()
        String(initializedGlobal == nil)
        """#, lazyTopLevelGlobals: true)

        #expect(interpreted == native)
    }

    @Test func hostWeakReferencesConfirmReleasedInstancesLeaveTheHeap() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: #"""
        final class HeapProbe {
            var first = 1
            var second = "payload"
        }
        """#)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "HeapProbe" })

        var references: [NativeWeakInstanceReference] = []
        do {
            var values: [RuntimeValue] = []
            values.reserveCapacity(2_000)
            for _ in 0..<2_000 {
                let value = try interpreter.instantiate(
                    symbol, with: CallArguments())
                if case .instance(let instance) = value {
                    references.append(NativeWeakInstanceReference(instance))
                }
                values.append(value)
            }
            #expect(references.allSatisfy { $0.value != nil })
            withExtendedLifetime(values) {}
        }

        // Native weak references become nil only after the Swift heap object
        // has actually been deallocated; an interpreted deinit event alone
        // would not be sufficient evidence for this assertion.
        #expect(references.allSatisfy { $0.value == nil })
    }

    @Test func breakingAnInterpretedClosureCycleReclaimsTheHostInstance() throws {
        let interpreter = Interpreter()
        try interpreter.run(source: interpretedARCPrelude)
        let symbol = try #require(
            interpreter.structSymbols.first { $0.name == "Probe" })

        func makeCycle() throws -> NativeWeakInstanceReference {
            var value: RuntimeValue? = try interpreter.instantiate(
                symbol, with: CallArguments(arguments: [
                    .init(label: nil, value: .native("cycle"))
                ]))
            guard case .instance(let instance)? = value else {
                throw RuntimeError(message: "expected a Probe instance")
            }
            let reference = NativeWeakInstanceReference(instance)
            _ = try interpreter.callMethod(
                named: "installStrongCycle", on: instance, arguments: [])
            value = nil
            return reference
        }
        let reference = try makeCycle()

        // The callback still owns self, so dropping the external value is not
        // enough. Keep this assertion inside the instance's lexical scope.
        #expect(reference.value != nil)

        func breakCycle(_ reference: NativeWeakInstanceReference) {
            reference.value?.box(for: "callback")?.value = .nilValue
        }
        breakCycle(reference)
        #expect(reference.value == nil)
    }
}
