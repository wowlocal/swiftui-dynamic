import Foundation

extension String {
    func appending(_ other: String?) -> String {
        guard let value = other else {
            return "\(self)<nil>"
        }
        return "\(self.appending(value))<optional>"
    }
}

func sourceImportedStringOverloadOutput() async -> String {
    await Task.yield()

    let optionalSuffix: String? = ".log"
    let nilResult = "session".appending(nil)
    let stringResult = "file".appending(".txt")
    let optionalResult = "trace".appending(optionalSuffix)
    return "\(nilResult)|\(stringResult)|\(optionalResult)"
}

@MainActor
func parityNativeOutput() async throws -> String {
    await sourceImportedStringOverloadOutput()
}
