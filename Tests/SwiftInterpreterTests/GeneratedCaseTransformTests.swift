import Testing
@testable import SwiftInterpreter

@Suite struct GeneratedCaseTransformTests {
    @Test func stdlibResultTransformsAreDerivedByGenericSlot() throws {
        let successMap = try #require(
            GeneratedCaseTransformSurface.operation(
                nominalName: "Swift.Result<Int, Error>",
                memberName: "map"))
        #expect(successMap.selectedCaseName == "success")
        #expect(successMap.argumentLabel == nil)
        if case .payload = successMap.application {
            // Expected.
        } else {
            Issue.record("Result.map should transform its success payload")
        }

        let failureMap = try #require(
            GeneratedCaseTransformSurface.operation(
                nominalName: "Result",
                memberName: "mapError"))
        #expect(failureMap.selectedCaseName == "failure")
        if case .payload = failureMap.application {
            // Expected.
        } else {
            Issue.record("Result.mapError should transform its failure payload")
        }

        let successFlatMap = try #require(
            GeneratedCaseTransformSurface.operation(
                nominalName: "Result",
                memberName: "flatMap"))
        #expect(successFlatMap.selectedCaseName == "success")
        if case .carrier = successFlatMap.application {
            // Expected.
        } else {
            Issue.record("Result.flatMap should return the callback carrier")
        }

        let failureFlatMap = try #require(
            GeneratedCaseTransformSurface.operation(
                nominalName: "Result",
                memberName: "flatMapError"))
        #expect(failureFlatMap.selectedCaseName == "failure")
        if case .carrier = failureFlatMap.application {
            // Expected.
        } else {
            Issue.record(
                "Result.flatMapError should return the callback carrier")
        }

        #expect(GeneratedCaseTransformSurface.containsCase(
            "success", nominalName: "Swift.Result<Int, Error>"))
        #expect(GeneratedCaseTransformSurface.containsCase(
            "failure", nominalName: "Result"))
        #expect(GeneratedCaseTransformSurface.operation(
            nominalName: "Result", memberName: "description") == nil)
    }

    @Test func generatedPayloadTransformsPreserveOppositeCases() throws {
        let value = try Interpreter().run(source: """
        enum ProbeError: Error {
            case original
            case widened
        }

        let success: Result<Int, ProbeError> = .success(29)
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
        case .success:
            failureText = "unexpected"
        case .failure(.widened):
            failureText = "widened"
        default:
            failureText = "original"
        }
        "\\(successText)|\\(failureText)"
        """)

        #expect(value.stringValue == "value:29|widened")
    }
}
