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

        // Drain both pipes while the child runs. Reading only after exit
        // deadlocks once the child fills a pipe buffer (about 64 KB).
        var errorData = Data()
        let errorDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorDone.signal()
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        errorDone.wait()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
