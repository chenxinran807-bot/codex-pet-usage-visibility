import Foundation

protocol AppServerClientProtocol: Sendable {
    var rateLimitUpdates: AsyncStream<AccountRateLimitsUpdatedNotification> { get }
    func start() async throws
    func readAccount() async throws -> GetAccountResponse
    func readRateLimits() async throws -> GetAccountRateLimitsResponse
    func stop() async
}

protocol AppServerLineTransport: Sendable {
    func start() async throws -> AsyncThrowingStream<String, Error>
    func send(_ line: String) async throws
    func stop() async
}

enum AppServerClientError: Error, Equatable, Sendable {
    case alreadyStarted
    case notConnected
    case disconnected
    case malformedMessage
    case rpcError(code: Int)
    case launchFailed
    case transportFailure
}

protocol ExecutableFileChecking: Sendable {
    func resolvedPath(_ path: String) -> String
    func isExecutableFile(atPath path: String) -> Bool
    func isRegularFile(atPath path: String) -> Bool
}

struct SystemExecutableFiles: ExecutableFileChecking {
    func resolvedPath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
    func isExecutableFile(atPath path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
    func isRegularFile(atPath path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular
    }
}

protocol CodexExecutableResolving: Sendable {
    func resolve() throws -> URL
}

struct CodexExecutableResolver: CodexExecutableResolving {
    private let environment: [String: String]
    private let homeDirectory: URL
    private let files: any ExecutableFileChecking

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        files: any ExecutableFileChecking = SystemExecutableFiles()
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.files = files
    }

    func resolve() throws -> URL {
        if let override = environment["CODEX_EXECUTABLE_PATH"], !override.isEmpty {
            guard override.hasPrefix("/") else { throw AppServerClientError.launchFailed }
            let standardized = URL(fileURLWithPath: override).standardizedFileURL.path
            let path = files.resolvedPath(standardized)
            guard files.isExecutableFile(atPath: path), files.isRegularFile(atPath: path) else {
                throw AppServerClientError.launchFailed
            }
            return URL(fileURLWithPath: path)
        }
        let known = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            homeDirectory.appendingPathComponent(".local/bin/codex").path
        ]
        let pathCandidates = environment["PATH", default: ""]
            .split(separator: ":", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }
        let candidates = (known + pathCandidates)
            .map { files.resolvedPath(URL(fileURLWithPath: $0).standardizedFileURL.path) }
        guard let path = candidates.first(where: { files.isExecutableFile(atPath: $0) && files.isRegularFile(atPath: $0) }) else {
            throw AppServerClientError.launchFailed
        }
        return URL(fileURLWithPath: path)
    }
}

actor AppServerClient: AppServerClientProtocol {
    nonisolated let rateLimitUpdates: AsyncStream<AccountRateLimitsUpdatedNotification>

    private enum PendingRequest {
        case initialize(CheckedContinuation<Void, Error>)
        case account(CheckedContinuation<GetAccountResponse, Error>)
        case rateLimits(CheckedContinuation<GetAccountRateLimitsResponse, Error>)
    }

    private let transport: any AppServerLineTransport
    private let updateContinuation: AsyncStream<AccountRateLimitsUpdatedNotification>.Continuation
    private var pending: [Int: PendingRequest] = [:]
    private var nextID = 1
    private var listener: Task<Void, Never>?
    private var started = false
    private var initialized = false
    private var stopped = false

    var pendingRequestCount: Int { pending.count }

    init(transport: any AppServerLineTransport = ProcessAppServerLineTransport()) {
        var continuation: AsyncStream<AccountRateLimitsUpdatedNotification>.Continuation!
        rateLimitUpdates = AsyncStream { continuation = $0 }
        updateContinuation = continuation
        self.transport = transport
    }

    func start() async throws {
        guard !started else { throw AppServerClientError.alreadyStarted }
        guard !stopped else { throw AppServerClientError.disconnected }
        started = true
        do {
            let lines = try await transport.start()
            listener = Task { [weak self] in
                do {
                    for try await line in lines { await self?.receive(line) }
                    await self?.disconnect(with: .disconnected)
                } catch {
                    await self?.disconnect(with: .transportFailure)
                }
            }
            let id = allocateID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pending[id] = .initialize(continuation)
                    Task { [transport] in
                        do { try await transport.send(Self.initializeLine(id: id)) }
                        catch { self.failRequest(id: id, error: .transportFailure) }
                    }
                }
            } onCancel: {
                Task { await self.cancelRequest(id: id) }
            }
            try Task.checkCancellation()
            try await transport.send(Self.initializedLine)
            try Task.checkCancellation()
            initialized = true
        } catch {
            if error is CancellationError || Task.isCancelled {
                await disconnect(with: .disconnected)
                throw CancellationError()
            }
            let clientError = error as? AppServerClientError ?? .transportFailure
            await disconnect(with: clientError)
            throw clientError
        }
    }

    func readRateLimits() async throws -> GetAccountRateLimitsResponse {
        guard initialized, !stopped else { throw AppServerClientError.notConnected }
        let id = allocateID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = .rateLimits(continuation)
                Task { [transport] in
                    do { try await transport.send(Self.readLine(id: id)) }
                    catch { self.failRequest(id: id, error: .transportFailure) }
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id) }
        }
    }

    func readAccount() async throws -> GetAccountResponse {
        guard initialized, !stopped else { throw AppServerClientError.notConnected }
        let id = allocateID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                pending[id] = .account(continuation)
                Task { [transport] in
                    do { try await transport.send(Self.accountReadLine(id: id)) }
                    catch { self.failRequest(id: id, error: .transportFailure) }
                }
            }
        } onCancel: { Task { await self.cancelRequest(id: id) } }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        initialized = false
        failAll(with: .disconnected)
        listener?.cancel()
        listener = nil
        updateContinuation.finish()
        await transport.stop()
    }

    private func allocateID() -> Int { defer { nextID += 1 }; return nextID }

    private func receive(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { await disconnect(with: .malformedMessage); return }

        if let method = object["method"] as? String {
            guard method == "account/rateLimits/updated",
                  let params = object["params"],
                  let paramsData = try? JSONSerialization.data(withJSONObject: params),
                  let update = try? JSONDecoder().decode(AccountRateLimitsUpdatedNotification.self, from: paramsData)
            else {
                if method == "account/rateLimits/updated" { await disconnect(with: .malformedMessage) }
                return
            }
            updateContinuation.yield(update)
            return
        }

        guard let id = object["id"] as? Int, let request = pending.removeValue(forKey: id) else { return }
        if let rpcError = object["error"] as? [String: Any], let code = rpcError["code"] as? Int {
            resume(request, throwing: .rpcError(code: code))
            return
        }
        guard let result = object["result"],
              let resultData = try? JSONSerialization.data(withJSONObject: result)
        else { resume(request, throwing: .malformedMessage); return }

        switch request {
        case .initialize(let continuation):
            guard (try? JSONDecoder().decode(InitializeResponse.self, from: resultData)) != nil else {
                continuation.resume(throwing: AppServerClientError.malformedMessage); return
            }
            continuation.resume()
        case .rateLimits(let continuation):
            do { continuation.resume(returning: try JSONDecoder().decode(GetAccountRateLimitsResponse.self, from: resultData)) }
            catch { continuation.resume(throwing: AppServerClientError.malformedMessage) }
        case .account(let continuation):
            do { continuation.resume(returning: try JSONDecoder().decode(GetAccountResponse.self, from: resultData)) }
            catch { continuation.resume(throwing: AppServerClientError.malformedMessage) }
        }
    }

    private func failRequest(id: Int, error: AppServerClientError) {
        guard let request = pending.removeValue(forKey: id) else { return }
        resume(request, throwing: error)
    }

    private func cancelRequest(id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        switch request {
        case .initialize(let continuation): continuation.resume(throwing: CancellationError())
        case .account(let continuation): continuation.resume(throwing: CancellationError())
        case .rateLimits(let continuation): continuation.resume(throwing: CancellationError())
        }
    }

    private func disconnect(with error: AppServerClientError) async {
        guard !stopped else { return }
        stopped = true
        initialized = false
        failAll(with: error)
        updateContinuation.finish()
        listener?.cancel()
        listener = nil
        await transport.stop()
    }

    private func failAll(with error: AppServerClientError) {
        let requests = pending.values
        pending.removeAll()
        for request in requests { resume(request, throwing: error) }
    }

    private func resume(_ request: PendingRequest, throwing error: AppServerClientError) {
        switch request {
        case .initialize(let continuation): continuation.resume(throwing: error)
        case .account(let continuation): continuation.resume(throwing: error)
        case .rateLimits(let continuation): continuation.resume(throwing: error)
        }
    }

    private static func initializeLine(id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"clientInfo":{"name":"quota-overlay","version":"1.0"},"capabilities":{}}}"#
    }

    private static func readLine(id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"account/rateLimits/read","params":{}}"#
    }

    private static func accountReadLine(id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"account/read","params":{"refreshToken":false}}"#
    }

    private static let initializedLine = #"{"jsonrpc":"2.0","method":"initialized"}"#
}

private struct InitializeResponse: Decodable {
    let codexHome: String
    let platformFamily: String
    let platformOs: String
    let userAgent: String
}

struct AppServerProcessChannels: Sendable {
    let standardInput: FileHandle
    let standardOutput: FileHandle
}

protocol AppServerProcessRunner: Sendable {
    func launch(executableURL: URL, arguments: [String]) async throws -> AppServerProcessChannels
    func terminate() async
    func waitUntilExit() async
}

protocol AppServerLineWriter: Sendable {
    func send(_ data: Data) async throws
    func stop() async
}

actor FileHandleLineWriter: AppServerLineWriter {
    private let handle: FileHandle
    private var tail: Task<Void, Error>?
    private var stopped = false

    init(handle: FileHandle) { self.handle = handle }

    func send(_ data: Data) async throws {
        guard !stopped else { throw AppServerClientError.disconnected }
        let previous = tail
        let handle = self.handle
        let write = Task {
            if let previous { try await previous.value }
            try Task.checkCancellation()
            try await Task.detached { try handle.write(contentsOf: data) }.value
        }
        tail = write
        do { try await write.value }
        catch {
            if stopped || Task.isCancelled { throw AppServerClientError.disconnected }
            throw AppServerClientError.transportFailure
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        tail?.cancel()
        try? handle.close()
        tail = nil
    }
}

actor FoundationAppServerProcessRunner: AppServerProcessRunner {
    private var process: Process?

    func launch(executableURL: URL, arguments: [String]) async throws -> AppServerProcessChannels {
        guard process == nil else { throw AppServerClientError.alreadyStarted }
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw AppServerClientError.launchFailed }
        self.process = process
        return AppServerProcessChannels(
            standardInput: stdinPipe.fileHandleForWriting,
            standardOutput: stdoutPipe.fileHandleForReading
        )
    }

    func terminate() async {
        if let process, process.isRunning { process.terminate() }
    }

    func waitUntilExit() async {
        guard let process else { return }
        await Task.detached { process.waitUntilExit() }.value
        self.process = nil
    }
}

actor ProcessAppServerLineTransport: AppServerLineTransport {
    /// Maximum UTF-8 payload size, excluding the terminating LF. A payload of exactly this size is valid.
    static let maximumLineByteCount = 1_048_576
    static let largeLineStorageReleaseThreshold = 65_536

    private let executableResolver: any CodexExecutableResolving
    private let arguments: [String]
    private let runner: any AppServerProcessRunner
    private let writerFactory: @Sendable (FileHandle) -> any AppServerLineWriter
    private let bufferReleaseObserver: (@Sendable (Int) -> Void)?
    private var writer: (any AppServerLineWriter)?
    private var output: FileHandle?
    private var reader: Task<Void, Never>?
    private var started = false
    private var stopped = false

    init(
        executableResolver: any CodexExecutableResolving = CodexExecutableResolver(),
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        runner: any AppServerProcessRunner = FoundationAppServerProcessRunner(),
        writerFactory: @escaping @Sendable (FileHandle) -> any AppServerLineWriter = { FileHandleLineWriter(handle: $0) },
        bufferReleaseObserver: (@Sendable (Int) -> Void)? = nil
    ) {
        self.executableResolver = executableResolver
        self.arguments = arguments
        self.runner = runner
        self.writerFactory = writerFactory
        self.bufferReleaseObserver = bufferReleaseObserver
    }

    func start() async throws -> AsyncThrowingStream<String, Error> {
        guard !started else { throw AppServerClientError.alreadyStarted }
        started = true
        let executableURL = try executableResolver.resolve()
        let channels = try await runner.launch(executableURL: executableURL, arguments: arguments)
        writer = writerFactory(channels.standardInput)
        let output = channels.standardOutput
        self.output = output
        let bufferReleaseObserver = self.bufferReleaseObserver
        let stream = AsyncThrowingStream<String, Error> { continuation in
            reader = Task.detached {
                var buffer = Data()
                do {
                    for try await byte in output.bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        guard byte == 0x0A else {
                            guard buffer.count <= Self.maximumLineByteCount else {
                                buffer = Data()
                                continuation.finish(throwing: AppServerClientError.malformedMessage)
                                return
                            }
                            continue
                        }
                        let newline = buffer.index(before: buffer.endIndex)
                        let lineData = buffer[..<newline]
                        let completedByteCount = buffer.count
                        if completedByteCount >= Self.largeLineStorageReleaseThreshold {
                            buffer = Data()
                            bufferReleaseObserver?(completedByteCount)
                        } else {
                            buffer.removeAll(keepingCapacity: true)
                        }
                        guard let line = String(data: lineData, encoding: .utf8) else {
                            continuation.finish(throwing: AppServerClientError.malformedMessage); return
                        }
                        continuation.yield(line)
                    }
                } catch is CancellationError {
                    continuation.finish()
                    return
                } catch {
                    continuation.finish(throwing: AppServerClientError.transportFailure)
                    return
                }
                if !buffer.isEmpty { continuation.finish(throwing: AppServerClientError.malformedMessage) }
                else { continuation.finish() }
            }
        }
        return stream
    }

    func send(_ line: String) async throws {
        guard let writer, let data = (line + "\n").data(using: .utf8) else { throw AppServerClientError.disconnected }
        try await writer.send(data)
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        let readTask = reader
        readTask?.cancel()
        reader = nil
        await writer?.stop()
        writer = nil
        await runner.terminate()
        await readTask?.value
        try? output?.close()
        output = nil
        await runner.waitUntilExit()
    }
}
