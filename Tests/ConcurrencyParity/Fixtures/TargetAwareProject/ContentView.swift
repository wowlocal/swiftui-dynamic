import SwiftUI

struct ContentView: View {
    var body: some View {
        let operatingSystem = selectedOperatingSystem()
        let architecture = selectedArchitecture()
        let configuration = selectedConfiguration()
        let environment = selectedEnvironment()
        let availableModule = selectedAvailableModule()
        let missingModule = selectedMissingModule()
        let unavailableModuleVersion = selectedUnavailableModuleVersion()
        let missingModuleVersion = selectedMissingModuleVersion()
        let swiftVersion = selectedSwiftConditionalVersion()
        let compilerVersion = selectedCompilerVersion()
        let defaultIsolation = selectedDefaultIsolation()
        let deployment = selectedDeployment()
        return Text(
            operatingSystem + "|" + architecture + "|" + configuration
                + "|" + environment + "|" + availableModule + "|"
                + missingModule + "|" + unavailableModuleVersion + "|"
                + missingModuleVersion + "|" + swiftVersion + "|"
                + compilerVersion + "|"
                + defaultIsolation + "|" + deployment)
    }
}
