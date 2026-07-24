import Testing
@testable import SwiftInterpreter

private final class NativeNonmutatingProxyStorage {
    var values: [Int: Int] = [:]
}

private struct NativeNonmutatingProxy {
    let storage: NativeNonmutatingProxyStorage

    subscript(key: Int) -> Int? {
        get { storage.values[key] }
        nonmutating set { storage.values[key] = newValue }
    }
}

private final class NativeNonmutatingProxyOwner {
    let storage = NativeNonmutatingProxyStorage()
    var proxy: NativeNonmutatingProxy { .init(storage: storage) }
}

@MainActor
@Suite("User subscript overloads")
struct UserSubscriptOverloadTests {
    @Test func rangeArgumentSelectsRangeSubscript() throws {
        let source = """
        struct Window {
            subscript(position: Int) -> Int {
                return position
            }

            subscript(bounds: Range<Int>) -> Int {
                return bounds.upperBound - bounds.lowerBound
            }
        }

        Window()[2..<7]
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 5)
    }

    /// Collection's generic RangeExpression default first resolves a partial
    /// or closed range against the receiver's indices, then invokes the
    /// collection's declared Range subscript. It must not fall back to an
    /// unrelated same-arity scalar subscript.
    @Test func rangeExpressionsSelectDeclaredRangeSubscript() throws {
        let source = """
        struct Window: RandomAccessCollection {
            typealias Index = Int
            typealias Element = Int
            typealias SubSequence = Window

            let storage: [Int]
            let lower: Int
            let upper: Int

            var startIndex: Int { lower }
            var endIndex: Int { upper }

            subscript(position: Int) -> Int {
                position * 10 + storage[position]
            }

            subscript(bounds: Range<Int>) -> Window {
                Window(
                    storage: storage,
                    lower: bounds.lowerBound,
                    upper: bounds.upperBound)
            }
        }

        let window = Window(
            storage: [10, 20, 30, 40], lower: 0, upper: 4)
        let tail = window[1...]
        let through = window[...2]
        let upTo = window[..<2]
        let closed = window[1...2]
        tail[tail.startIndex] * 1_000_000
            + through[through.endIndex - 1] * 10_000
            + upTo[upTo.endIndex - 1] * 100
            + closed[closed.startIndex]
        """

        let value = try Interpreter().run(source: source)
        #expect(value.intValue == 30_503_030)
    }

    @Test func nonmutatingSetterWritesThroughComputedStructProxy() throws {
        let nativeOwner = NativeNonmutatingProxyOwner()
        nativeOwner.proxy[7] = 41
        let native = nativeOwner.proxy[7]

        let source = """
        final class Storage {
            var values: [Int: Int] = [:]
        }

        struct Proxy {
            let storage: Storage

            subscript(key: Int) -> Int? {
                get { storage.values[key] }
                nonmutating set { storage.values[key] = newValue }
            }
        }

        final class Owner {
            let storage = Storage()
            var proxy: Proxy { .init(storage: storage) }
        }

        let owner = Owner()
        owner.proxy[7] = 41
        owner.proxy[7] ?? -1
        """

        let interpreted = try Interpreter().run(source: source)
        #expect(interpreted.intValue == native)
    }
}
