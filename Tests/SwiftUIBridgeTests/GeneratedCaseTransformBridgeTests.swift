import Testing
import SwiftInterpreter
@testable import SwiftUIBridge

@Suite struct GeneratedCaseTransformBridgeTests {
    /// The replay registry supplies its specialized ResultBox carrier. The
    /// generated stdlib adapter must therefore dispatch by capability rather
    /// than only supporting the core no-registry carrier.
    @Test func resultBoxMapErrorPreservesCaseAndTransformsFailure() throws {
        let value = try Interpreter(registry: ViewRegistry()).run(source: """
        enum ProbeError: Error {
            case original
            case widened
        }

        let success: Result<Int, ProbeError> = .success(31)
        let mappedSuccess = success.mapError { _ in ProbeError.widened }

        let failure: Result<Int, ProbeError> = .failure(.original)
        let mappedFailure = failure.mapError { _ in ProbeError.widened }

        let successText: String
        switch mappedSuccess {
        case .success(let value):
            successText = "value:\\(value)"
        case .failure:
            successText = "unexpected"
        }

        let failureText: String
        switch mappedFailure {
        case .failure(.widened):
            failureText = "widened"
        default:
            failureText = "unexpected"
        }
        "\\(successText)|\\(failureText)"
        """)

        #expect(value.stringValue == "value:31|widened")
    }
}
