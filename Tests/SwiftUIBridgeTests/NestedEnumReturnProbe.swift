import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct NestedEnumReturnProbe {
    @Test func implicitMemberReturnsNestedEnum() throws {
        let source = """
        struct API2 {
            enum Endpoint {
                case popular
                case topRated
                func path() -> String {
                    switch self {
                    case .popular: return "movie/popular"
                    case .topRated: return "movie/top_rated"
                    }
                }
            }
        }
        enum Menu: Int, CaseIterable {
            case popular, topRated
            func endpoint() -> API2.Endpoint {
                switch self {
                case .popular: return .popular
                case .topRated: return .topRated
                }
            }
        }
        Menu.popular.endpoint().path() + "|" + Menu.topRated.endpoint().path()
        """
        let result = try Interpreter(registry: TraceRegistry()).run(source: source)
        print("NESTED ENUM: \(result.stringValue ?? "NIL(\(result.stringified))")")
        #expect(result.stringValue == "movie/popular|movie/top_rated")
    }
}
