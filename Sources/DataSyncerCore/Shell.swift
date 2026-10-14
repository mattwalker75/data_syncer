// Running a command-line tool (ssh, scp, ssh-add…) from async code: collect its output, feed it a file, or
// stream its output to a file — with cancellation (the process is ended) and no pipe deadlocks.
import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String
    public var ok: Bool { status == 0 }
    public var text: String { String(decoding: stdout, as: UTF8.self) }
}

public enum Shell {
    /// A write into a pipe whose reader has gone must come back as an error, never as SIGPIPE killing the app.
    static func noSigpipe(_ pipe: Pipe) {
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Runs `executable` with `arguments`, optionally feeding `stdin`, and returns everything it printed.
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           stdin: Data? = nil) async throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        noSigpipe(inp)
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        let cancelled = Locked(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShellResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if cancelled.value || Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                    do { try p.run() } catch { cont.resume(throwing: DSError("Could not start \(executable): \(error.localizedDescription)")); return }
                    if cancelled.value { p.terminate() }   // a cancel that landed while the process was starting
                    // readers on their own threads: a full pipe would otherwise block the child
                    let group = DispatchGroup()
                    var outData = Data(), errData = Data()
                    group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    var writeFailed = false
                    if let stdin { do { try inp.fileHandleForWriting.write(contentsOf: stdin) } catch { writeFailed = true } }
                    try? inp.fileHandleForWriting.close()
                    p.waitUntilExit()
                    group.wait()
                    if cancelled.value { cont.resume(throwing: CancellationError()); return }
                    var result = ShellResult(status: p.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
                    if writeFailed && result.status == 0 { result.status = 1; result.stderr += "\nthe command stopped reading before everything was sent" }
                    cont.resume(returning: result)
                }
            }
        } onCancel: {
            cancelled.value = true
            if p.isRunning { p.terminate() }
        }
    }

    /// Runs a command and feeds it a local file on stdin, a chunk at a time, reporting the bytes sent so far.
    public static func feed(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                            file: URL, progress: (@Sendable (Int64) -> Void)?) async throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        noSigpipe(inp)
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        let cancelled = Locked(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShellResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if cancelled.value || Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                    let input: FileHandle
                    do { input = try FileHandle(forReadingFrom: file) } catch { cont.resume(throwing: DSError("\(file.lastPathComponent) could not be read: \(error.localizedDescription)")); return }
                    defer { try? input.close() }
                    do { try p.run() } catch { cont.resume(throwing: DSError("Could not start \(executable): \(error.localizedDescription)")); return }
                    if cancelled.value { p.terminate() }   // a cancel that landed while the process was starting
                    let group = DispatchGroup()
                    var outData = Data(), errData = Data()
                    group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    var sent: Int64 = 0
                    var writeFailed = false
                    while !cancelled.value {
                        let chunk = input.readData(ofLength: 1 << 20)
                        if chunk.isEmpty { break }
                        do { try inp.fileHandleForWriting.write(contentsOf: chunk) } catch { writeFailed = true; break }
                        sent += Int64(chunk.count)
                        progress?(sent)
                    }
                    try? inp.fileHandleForWriting.close()
                    p.waitUntilExit()
                    group.wait()
                    if cancelled.value { cont.resume(throwing: CancellationError()); return }
                    var result = ShellResult(status: p.terminationStatus, stdout: outData, stderr: String(decoding: errData, as: UTF8.self))
                    if writeFailed && result.status == 0 { result.status = 1; result.stderr += "\nthe connection closed before the file was fully sent" }
                    cont.resume(returning: result)
                }
            }
        } onCancel: {
            cancelled.value = true
            if p.isRunning { p.terminate() }
        }
    }

    /// Runs a command and writes everything it prints to a local file.
    public static func drain(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                             to file: URL) async throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        let cancelled = Locked(false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ShellResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if cancelled.value || Task.isCancelled { cont.resume(throwing: CancellationError()); return }
                    FileManager.default.createFile(atPath: file.path, contents: nil)
                    let output: FileHandle
                    do { output = try FileHandle(forWritingTo: file) } catch { cont.resume(throwing: DSError("\(file.path) could not be written: \(error.localizedDescription)")); return }
                    defer { try? output.close() }
                    do { try p.run() } catch { cont.resume(throwing: DSError("Could not start \(executable): \(error.localizedDescription)")); return }
                    if cancelled.value { p.terminate() }   // a cancel that landed while the process was starting
                    let group = DispatchGroup()
                    var errData = Data()
                    group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                    var writeError: String?
                    while true {
                        let chunk = out.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        do { try output.write(contentsOf: chunk) } catch { writeError = error.localizedDescription; p.terminate(); break }
                    }
                    p.waitUntilExit()
                    group.wait()
                    if cancelled.value { cont.resume(throwing: CancellationError()); return }
                    if let writeError { cont.resume(throwing: DSError("\(file.path) could not be written: \(writeError)")); return }
                    cont.resume(returning: ShellResult(status: p.terminationStatus, stdout: Data(), stderr: String(decoding: errData, as: UTF8.self)))
                }
            }
        } onCancel: {
            cancelled.value = true
            if p.isRunning { p.terminate() }
        }
    }

    /// Single-quotes a string for a POSIX shell.
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// A value shared with a background thread.
final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&v) }
}
