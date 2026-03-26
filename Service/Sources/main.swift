import Foundation
import Shared
import Darwin

// MARK: - LaunchAgent Bootstrap

enum ServiceBootstrapError: Error {
    case missingExecutablePath
    case commandFailed(String)
}

enum ServiceBootstrap {
    static let label = XPCConnectionHelper.machServiceName
    static let fileManager = FileManager.default

    static var currentExecutableURL: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    }

    static var installRootURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FireBox/Service", isDirectory: true)
    }

    static var installExecutableURL: URL {
        installRootURL.appendingPathComponent("Service", isDirectory: false)
    }

    static var installFrameworksURL: URL {
        installRootURL.appendingPathComponent("Frameworks", isDirectory: true)
    }

    static var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist", isDirectory: false)
    }

    static var launchDomain: String {
        "gui/\(getuid())"
    }
}

func runCommand(_ launchPath: String, _ arguments: [String]) -> (status: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (-1, "", error.localizedDescription)
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)
    return (process.terminationStatus, stdout, stderr)
}

func copyReplacingItem(from sourceURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    if sourceURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
        return
    }
    if fileManager.fileExists(atPath: destinationURL.path) {
        try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.copyItem(at: sourceURL, to: destinationURL)
}

func installServiceArtifactsIfNeeded() throws {
    let fileManager = FileManager.default
    let currentExecutableURL = ServiceBootstrap.currentExecutableURL

    guard fileManager.fileExists(atPath: currentExecutableURL.path) else {
        throw ServiceBootstrapError.missingExecutablePath
    }

    try fileManager.createDirectory(at: ServiceBootstrap.installRootURL, withIntermediateDirectories: true)
    try copyReplacingItem(from: currentExecutableURL, to: ServiceBootstrap.installExecutableURL)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ServiceBootstrap.installExecutableURL.path)

    let sourceFrameworkURL = Bundle(for: XPCConnectionHelper.self).bundleURL.resolvingSymlinksInPath()
    let destinationFrameworkURL = ServiceBootstrap.installFrameworksURL.appendingPathComponent("Shared.framework", isDirectory: true)
    try fileManager.createDirectory(at: ServiceBootstrap.installFrameworksURL, withIntermediateDirectories: true)
    try copyReplacingItem(from: sourceFrameworkURL, to: destinationFrameworkURL)
}

func writeLaunchAgentPlist() throws {
    let fileManager = FileManager.default
    let launchAgentDirectory = ServiceBootstrap.launchAgentURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: launchAgentDirectory, withIntermediateDirectories: true)

    let plist: [String: Any] = [
        "Label": ServiceBootstrap.label,
        "ProgramArguments": [
            ServiceBootstrap.installExecutableURL.path,
        ],
        "RunAtLoad": true,
        "KeepAlive": true,
        "MachServices": [
            ServiceBootstrap.label: true,
        ],
        "StandardOutPath": "/tmp/\(ServiceBootstrap.label).log",
        "StandardErrorPath": "/tmp/\(ServiceBootstrap.label).err",
    ]

    let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try plistData.write(to: ServiceBootstrap.launchAgentURL, options: .atomic)
}

func bootstrapLaunchAgent() throws {
    _ = runCommand("/bin/launchctl", ["bootout", ServiceBootstrap.launchDomain, ServiceBootstrap.launchAgentURL.path])

    let bootstrapResult = runCommand("/bin/launchctl", ["bootstrap", ServiceBootstrap.launchDomain, ServiceBootstrap.launchAgentURL.path])
    guard bootstrapResult.status == 0 else {
        throw ServiceBootstrapError.commandFailed("launchctl bootstrap failed: \(bootstrapResult.stderr)")
    }

    _ = runCommand("/bin/launchctl", ["enable", "\(ServiceBootstrap.launchDomain)/\(ServiceBootstrap.label)"])
    _ = runCommand("/bin/launchctl", ["kickstart", "-k", "\(ServiceBootstrap.launchDomain)/\(ServiceBootstrap.label)"])
}

func ensureSelfRegisteredIfNeeded() {
    let environment = ProcessInfo.processInfo.environment
    if environment["LAUNCH_JOB_LABEL"] == ServiceBootstrap.label || environment["XPC_SERVICE_NAME"] == ServiceBootstrap.label {
        return
    }
    print("Service must be launched by launchd with label \(ServiceBootstrap.label). Refusing self-registration.")
    exit(EXIT_FAILURE)

}

// MARK: - Main

ensureSelfRegisteredIfNeeded()

let serviceCore: ServiceCore
do {
    serviceCore = try ServiceCore()
} catch {
    print("Failed to initialize ServiceCore persistence: \(error)")
    exit(EXIT_FAILURE)
}

Task {
    do {
        let restored = try await serviceCore.restoreState()

        print(
            """
            Restored service state:
            - Providers sync mode: CloudKit
            - Providers restored: \(restored.providerCount)
            - Routes restored: \(restored.routeCount)
            - Access records restored: \(restored.accessCount)
            """
        )
    } catch {
        print("Failed to restore service state: \(error)")
    }
}

let service = Service(core: serviceCore)
let delegate = ServiceDelegate(service: service)
let listener = NSXPCListener(machServiceName: XPCConnectionHelper.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
