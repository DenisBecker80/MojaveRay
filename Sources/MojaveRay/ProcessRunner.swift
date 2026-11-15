import Foundation

struct CommandResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

enum ProcessRunner {
    static func run(_ launchPath: String, arguments: [String], environment: [String: String]? = nil) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.launchPath = launchPath
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        if let environment = environment {
            process.environment = environment
        }

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}
