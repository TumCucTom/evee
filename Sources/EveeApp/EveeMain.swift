import Darwin
import Foundation

@main
enum EveeMain {
    static func main() {
        guard CommandLine.arguments.contains("--installation-self-test") else {
            EveeApplication.main()
            return
        }
        Task {
            let rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("evee-installation-self-test-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: rootURL) }
            do {
                try InstallationSelfTest.prepareResultReporting()
                try await InstallationSelfTest.run(rootURL: rootURL)
                try InstallationSelfTest.reportResult(status: .passed)
                print("Evee installation self-test passed")
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                try? InstallationSelfTest.reportResult(status: .failed)
                fputs("Evee installation self-test failed: \(error.localizedDescription)\n", stderr)
                Darwin.exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}
