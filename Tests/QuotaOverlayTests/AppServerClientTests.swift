import Foundation
import Testing
@testable import QuotaOverlayApp

@Suite("App server client")
struct AppServerClientTests {
    @Test("account/read sends v2 request and decodes signed-out state")
    func readsAccountState() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readAccount() }
        let request = try await transport.nextSentObject()
        #expect(request.method == "account/read")
        let id = try #require(request.id)
        await transport.receive(#"{"jsonrpc":"2.0","id":\#(id),"result":{"account":null,"requiresOpenaiAuth":true}}"#)
        let result = try await read.value
        #expect(result.account == nil)
        #expect(result.requiresOpenaiAuth)
        await client.stop()
    }
    @Test("initialize completes before the rate-limit read is sent")
    func initializeBeforeRead() async throws {
        let transport = FakeLineTransport()
        let client = AppServerClient(transport: transport)
        let connect = Task { try await client.start() }

        let initialize = try await transport.nextSentObject()
        #expect(initialize.method == "initialize")
        #expect(initialize.params?.clientInfo != nil)
        let initializeID = try #require(initialize.id)
        await transport.receive(#"{"jsonrpc":"2.0","id":\#(initializeID),"result":{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos","userAgent":"test"}}"#)
        try await connect.value

        let initialized = try await transport.nextSentObject()
        #expect(initialized.method == "initialized")
        #expect(initialized.id == nil)
        #expect(initialized.params == nil)

        let read = Task { try await client.readRateLimits() }
        let request = try await transport.nextSentObject()
        #expect(request.method == "account/rateLimits/read")
        let readID = try #require(request.id)
        #expect(readID != initializeID)
        await transport.receive(response(id: readID, usedPercent: 37))
        #expect(try await read.value.rateLimits.primary?.usedPercent == 37)
        await client.stop()
    }

    @Test("concurrent reads correlate out-of-order responses by id")
    func correlatesOutOfOrderResponses() async throws {
        let (client, transport) = try await connectedClient()
        let first = Task { try await client.readRateLimits() }
        let firstRequest = try await transport.nextSentObject()
        let second = Task { try await client.readRateLimits() }
        let secondRequest = try await transport.nextSentObject()
        let firstID = try #require(firstRequest.id)
        let secondID = try #require(secondRequest.id)

        await transport.receive(response(id: secondID, usedPercent: 82))
        await transport.receive(response(id: firstID, usedPercent: 14))
        #expect(try await first.value.rateLimits.primary?.usedPercent == 14)
        #expect(try await second.value.rateLimits.primary?.usedPercent == 82)
        await client.stop()
    }

    @Test("rate-limit update notification is yielded")
    func yieldsUpdate() async throws {
        let (client, transport) = try await connectedClient()
        let update = Task { try await client.rateLimitUpdates.firstValue() }
        await transport.receive(#"{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":61}}}}"#)
        #expect(try await update.value.rateLimits.primary?.usedPercent == 61)
        await client.stop()
    }

    @Test("JSON-RPC errors are typed and sanitized")
    func rpcError() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readRateLimits() }
        let request = try await transport.nextSentObject()
        let id = try #require(request.id)
        await transport.receive(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"account abc token secret"}}"#)
        await #expect(throws: AppServerClientError.rpcError(code: -32000)) { try await read.value }
        await client.stop()
    }

    @Test("malformed messages fail pending calls without exposing payload")
    func malformedMessage() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readRateLimits() }
        _ = try await transport.nextSentObject()
        await transport.receive("{private-token")
        await #expect(throws: AppServerClientError.malformedMessage) { try await read.value }
        await client.stop()
    }

    @Test("malformed correlated response disconnects with a sanitized error")
    func malformedCorrelatedResponse() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readRateLimits() }
        let request = try await transport.nextSentObject()
        await transport.receive(#"{"jsonrpc":"2.0","id":\#(request.id!),"result":{"private":"account-id"}}"#)
        await #expect(throws: AppServerClientError.malformedMessage) { try await read.value }
        await client.stop()
    }

    @Test("malformed rate-limit update disconnects and finishes updates")
    func malformedUpdate() async throws {
        let (client, transport) = try await connectedClient()
        let end = Task { await client.rateLimitUpdates.collectToEnd() }
        await transport.receive(#"{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"account":"private"}}"#)
        #expect(await end.value.isEmpty)
        #expect(await transport.stopCount == 1)
    }

    @Test("EOF fails pending calls and finishes updates")
    func eofDisconnects() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readRateLimits() }
        _ = try await transport.nextSentObject()
        let updateEnd = Task { await client.rateLimitUpdates.collectToEnd() }
        await transport.finish()
        await #expect(throws: AppServerClientError.disconnected) { try await read.value }
        #expect(await updateEnd.value.isEmpty)
        #expect(await transport.stopCount == 1)
    }

    @Test("stop fails a pending read once and finishes updates")
    func stopWhileReadPending() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readRateLimits() }
        _ = try await transport.nextSentObject()
        let updateEnd = Task { await client.rateLimitUpdates.collectToEnd() }
        await client.stop()
        await #expect(throws: AppServerClientError.disconnected) { try await read.value }
        #expect(await updateEnd.value.isEmpty)
        #expect(await transport.stopCount == 1)
    }

    @Test("process transport uses production command and waits for exit on stop")
    func processLifecycle() async throws {
        let runner = FakeProcessRunner()
        let executable = URL(fileURLWithPath: "/custom/codex")
        let transport = ProcessAppServerLineTransport(executableResolver: FixedExecutableResolver(executable), runner: runner)
        _ = try await transport.start()
        #expect(await runner.executableURL == executable)
        #expect(await runner.arguments == ["app-server", "--listen", "stdio://"])
        await transport.stop()
        await transport.stop()
        #expect(await runner.terminateCount == 1)
        #expect(await runner.waitCount == 1)
    }

    @Test("resolver honors an executable override with a minimal Finder PATH")
    func resolverOverrideWithMinimalPath() throws {
        let files = FakeExecutableFiles(executables: ["/Applications/Codex CLI/codex"])
        let resolver = CodexExecutableResolver(
            environment: ["PATH": "/usr/bin:/bin", "CODEX_EXECUTABLE_PATH": "/Applications/Codex CLI/codex"],
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            files: files
        )
        #expect(try resolver.resolve().path == "/Applications/Codex CLI/codex")
    }

    @Test("resolver checks GUI-safe known locations before PATH")
    func resolverKnownLocationsWithMinimalPath() throws {
        let files = FakeExecutableFiles(executables: ["/opt/homebrew/bin/codex", "/usr/bin/codex"])
        let resolver = CodexExecutableResolver(
            environment: ["PATH": "/usr/bin:/bin"], homeDirectory: URL(fileURLWithPath: "/Users/test"), files: files
        )
        #expect(try resolver.resolve().path == "/opt/homebrew/bin/codex")
    }

    @Test("resolver rejects relative and non-executable overrides")
    func resolverRejectsInvalidOverrides() {
        let relative = CodexExecutableResolver(environment: ["CODEX_EXECUTABLE_PATH": "bin/codex"], homeDirectory: URL(fileURLWithPath: "/Users/test"), files: FakeExecutableFiles())
        #expect(throws: AppServerClientError.launchFailed) { try relative.resolve() }
        let missing = CodexExecutableResolver(environment: ["CODEX_EXECUTABLE_PATH": "/missing/codex"], homeDirectory: URL(fileURLWithPath: "/Users/test"), files: FakeExecutableFiles())
        #expect(throws: AppServerClientError.launchFailed) { try missing.resolve() }
        let directoryFiles = FakeExecutableFiles(executables: ["/Applications/Codex.app"], regularFiles: [])
        let directory = CodexExecutableResolver(environment: ["CODEX_EXECUTABLE_PATH": "/Applications/Codex.app"], homeDirectory: URL(fileURLWithPath: "/Users/test"), files: directoryFiles)
        #expect(throws: AppServerClientError.launchFailed) { try directory.resolve() }
    }

    @Test("resolver supports each known install tier and PATH fallback")
    func resolverKnownInstallTiers() throws {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(try CodexExecutableResolver(environment: [:], homeDirectory: home, files: FakeExecutableFiles(executables: ["/usr/local/bin/codex"])).resolve().path == "/usr/local/bin/codex")
        #expect(try CodexExecutableResolver(environment: [:], homeDirectory: home, files: FakeExecutableFiles(executables: ["/Users/test/.local/bin/codex"])).resolve().path == "/Users/test/.local/bin/codex")
        #expect(try CodexExecutableResolver(environment: ["PATH": "/custom/bin:/usr/bin"], homeDirectory: home, files: FakeExecutableFiles(executables: ["/custom/bin/codex"])).resolve().path == "/custom/bin/codex")
    }

    @Test("resolver precedence is override then known locations then PATH")
    func resolverPrecedence() throws {
        let all = FakeExecutableFiles(executables: ["/override/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/Users/test/.local/bin/codex", "/custom/bin/codex"])
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(try CodexExecutableResolver(environment: ["CODEX_EXECUTABLE_PATH": "/override/../override/codex", "PATH": "/custom/bin"], homeDirectory: home, files: all).resolve().path == "/override/codex")
        #expect(try CodexExecutableResolver(environment: ["PATH": "/custom/bin"], homeDirectory: home, files: all).resolve().path == "/opt/homebrew/bin/codex")
    }

    @Test("resolver follows an executable symlink to its regular absolute target")
    func resolverExecutableSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = root.appendingPathComponent("lib/codex-real")
        let link = root.appendingPathComponent("bin/codex")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: target.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755]))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = try CodexExecutableResolver(environment: ["CODEX_EXECUTABLE_PATH": link.path]).resolve()
        #expect(resolved.path == target.path)
    }


    @Test("process transport stop completes while a write is blocked")
    func blockedWriteDoesNotDeadlockStop() async throws {
        let runner = FakeProcessRunner()
        let writer = BlockingLineWriter()
        let transport = ProcessAppServerLineTransport(runner: runner, writerFactory: { _ in writer })
        _ = try await transport.start()
        let send = Task { try await transport.send("blocked") }
        await writer.waitUntilWriteStarted()
        await transport.stop()
        await #expect(throws: AppServerClientError.disconnected) { try await send.value }
        #expect(await writer.stopCount == 1)
        #expect(await runner.waitCount == 1)
    }

    @Test("process transport yields a short line while stdout remains open")
    func shortOpenPipeLine() async throws {
        let runner = FakeProcessRunner()
        let transport = ProcessAppServerLineTransport(runner: runner)
        let stream = try await transport.start()
        try await runner.writeOutput(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8) + Data([0x0A]))

        let line = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await line in stream { return line }
                throw AppServerClientError.disconnected
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw AppServerClientError.transportFailure
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
        #expect(line == #"{"jsonrpc":"2.0","id":1}"#)
        await transport.stop()
    }

    @Test("process transport rejects an oversized unterminated line while stdout remains open")
    func oversizedOpenPipeLine() async throws {
        let runner = FakeProcessRunner()
        let transport = ProcessAppServerLineTransport(runner: runner)
        let stream = try await transport.start()
        let secret = Data(repeating: 0x73, count: ProcessAppServerLineTransport.maximumLineByteCount + 1)

        let result = Task { () -> AppServerClientError? in
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error as? AppServerClientError
            }
        }
        try await runner.writeOutput(secret)

        #expect(await result.value == .malformedMessage)
        await transport.stop()
    }

    @Test("process transport accepts a line exactly at the byte limit")
    func exactMaximumLine() async throws {
        let runner = FakeProcessRunner()
        let transport = ProcessAppServerLineTransport(runner: runner)
        let stream = try await transport.start()
        let payload = Data(repeating: 0x61, count: ProcessAppServerLineTransport.maximumLineByteCount)
        try await runner.writeOutput(payload + Data([0x0A]))

        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next()?.utf8.count == ProcessAppServerLineTransport.maximumLineByteCount)
        await transport.stop()
    }

    @Test("process transport releases unusually large completed line storage")
    func releasesLargeLineStorage() async throws {
        let runner = FakeProcessRunner()
        let releases = BufferReleaseRecorder()
        let transport = ProcessAppServerLineTransport(
            runner: runner,
            bufferReleaseObserver: { byteCount in releases.record(byteCount) }
        )
        let stream = try await transport.start()
        let payload = Data(repeating: 0x61, count: ProcessAppServerLineTransport.largeLineStorageReleaseThreshold)
        try await runner.writeOutput(payload + Data([0x0A]))

        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()
        #expect(releases.values == [payload.count + 1])
        await transport.stop()
    }

    @Test("process transport buffers a line split across writes")
    func splitLineChunks() async throws {
        let runner = FakeProcessRunner()
        let transport = ProcessAppServerLineTransport(runner: runner)
        let stream = try await transport.start()
        try await runner.writeOutput(Data("split ".utf8))
        try await runner.writeOutput(Data("line\n".utf8))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == "split line")
        await transport.stop()
    }

    @Test("process transport yields multiple lines from one write")
    func multipleLinesInOneChunk() async throws {
        let runner = FakeProcessRunner()
        let transport = ProcessAppServerLineTransport(runner: runner)
        let stream = try await transport.start()
        try await runner.writeOutput(Data("one\ntwo\n".utf8))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == "one")
        #expect(try await iterator.next() == "two")
        await transport.stop()
    }

    @Test("process transport stop unblocks a pending pipe read")
    func stopWhilePipeReadBlocked() async throws {
        let runner = FakeProcessRunner()
        let transport = ProcessAppServerLineTransport(runner: runner)
        let stream = try await transport.start()
        let end = Task {
            do {
                for try await _ in stream {}
                return true
            } catch {
                return false
            }
        }
        await transport.stop()
        #expect(await end.value)
        #expect(await runner.waitCount == 1)
    }

    @Test("cancelling a read before its response resumes it with cancellation")
    func cancellationBeforeResponse() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readRateLimits() }
        let request = try await transport.nextSentObject()
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        await transport.receive(response(id: try #require(request.id), usedPercent: 20))
        #expect(await client.pendingRequestCount == 0)
        await client.stop()
    }

    @Test("cancellation racing a response resolves once without retaining pending work")
    func cancellationRacesResponse() async throws {
        let (client, transport) = try await connectedClient()
        let read = Task { try await client.readRateLimits() }
        let request = try await transport.nextSentObject()
        let id = try #require(request.id)
        let cancel = Task { read.cancel() }
        let respond = Task { await transport.receive(response(id: id, usedPercent: 44)) }
        await cancel.value
        await respond.value
        _ = try? await read.value
        #expect(await client.pendingRequestCount == 0)
        await client.stop()
    }

    @Test("cancellation racing stop and EOF resolves once")
    func cancellationRacesDisconnect() async throws {
        for disconnect in [Disconnect.stop, .eof] {
            let (client, transport) = try await connectedClient()
            let read = Task { try await client.readRateLimits() }
            _ = try await transport.nextSentObject()
            let cancel = Task { read.cancel() }
            let disconnectTask = Task {
                switch disconnect {
                case .stop: await client.stop()
                case .eof: await transport.finish()
                }
            }
            await cancel.value
            await disconnectTask.value
            _ = try? await read.value
            #expect(await client.pendingRequestCount == 0)
        }
    }

    @Test("cancelling start before initialize response preserves cancellation")
    func cancelStartBeforeInitializeResponse() async throws {
        let transport = FakeLineTransport()
        let client = AppServerClient(transport: transport)
        let start = Task { try await client.start() }
        _ = try await transport.nextSentObject()
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await client.pendingRequestCount == 0)
        #expect(await transport.stopCount == 1)
    }

    @Test("start cancellation winning a race with initialize response stays cancellation")
    func cancelStartRacesInitializeResponse() async throws {
        let transport = FakeLineTransport()
        let client = AppServerClient(transport: transport)
        let start = Task { try await client.start() }
        let request = try await transport.nextSentObject()
        let id = try #require(request.id)
        start.cancel()
        await transport.receive(#"{"jsonrpc":"2.0","id":\#(id),"result":{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos","userAgent":"test"}}"#)
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await client.pendingRequestCount == 0)
        #expect(await transport.stopCount == 1)
    }

    @Test("start cancellation winning a race with EOF stays cancellation")
    func cancelStartRacesEOF() async throws {
        let transport = FakeLineTransport()
        let client = AppServerClient(transport: transport)
        let start = Task { try await client.start() }
        _ = try await transport.nextSentObject()
        start.cancel()
        await transport.finish()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await client.pendingRequestCount == 0)
        #expect(await transport.stopCount == 1)
    }

    @Test("start cancellation winning a race with stop stays cancellation")
    func cancelStartRacesStop() async throws {
        let transport = FakeLineTransport()
        let client = AppServerClient(transport: transport)
        let start = Task { try await client.start() }
        _ = try await transport.nextSentObject()
        start.cancel()
        await client.stop()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await client.pendingRequestCount == 0)
        #expect(await transport.stopCount == 1)
    }

    @Test("stop is idempotent and closes the transport once")
    func idempotentStop() async throws {
        let (client, transport) = try await connectedClient()
        await client.stop()
        await client.stop()
        #expect(await transport.stopCount == 1)
    }

    private func connectedClient() async throws -> (AppServerClient, FakeLineTransport) {
        let transport = FakeLineTransport()
        let client = AppServerClient(transport: transport)
        let connect = Task { try await client.start() }
        let request = try await transport.nextSentObject()
        let id = try #require(request.id)
        await transport.receive(#"{"jsonrpc":"2.0","id":\#(id),"result":{"codexHome":"/tmp/codex","platformFamily":"unix","platformOs":"macos","userAgent":"test"}}"#)
        try await connect.value
        let initialized = try await transport.nextSentObject()
        #expect(initialized.method == "initialized")
        return (client, transport)
    }

    private func response(id: Int, usedPercent: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"result":{"rateLimits":{"primary":{"usedPercent":\#(usedPercent)}}}}"#
    }
}

private enum Disconnect { case stop, eof }

private actor FakeLineTransport: AppServerLineTransport {
    private var incomingContinuation: AsyncThrowingStream<String, Error>.Continuation?
    private var sent: [String] = []
    private var sendWaiters: [CheckedContinuation<String, Never>] = []
    private(set) var stopCount = 0

    func start() async throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in incomingContinuation = continuation }
    }

    func send(_ line: String) async throws {
        if let waiter = sendWaiters.first {
            sendWaiters.removeFirst()
            waiter.resume(returning: line)
        } else { sent.append(line) }
    }

    func stop() async {
        stopCount += 1
        incomingContinuation?.finish()
    }

    func receive(_ line: String) { incomingContinuation?.yield(line) }
    func finish() { incomingContinuation?.finish() }

    func nextSentObject() async throws -> SentRequest {
        let line: String
        if sent.isEmpty {
            line = await withCheckedContinuation { sendWaiters.append($0) }
        } else { line = sent.removeFirst() }
        return try JSONDecoder().decode(SentRequest.self, from: Data(line.utf8))
    }
}

private struct SentRequest: Decodable, Sendable {
    struct Params: Decodable, Sendable, Equatable {
        struct ClientInfo: Decodable, Sendable, Equatable { let name: String; let version: String }
        let clientInfo: ClientInfo?
    }
    let id: Int?
    let method: String
    let params: Params?
}

private actor FakeProcessRunner: AppServerProcessRunner {
    private(set) var executableURL: URL?
    private(set) var arguments: [String] = []
    private(set) var terminateCount = 0
    private(set) var waitCount = 0
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()

    func launch(executableURL: URL, arguments: [String]) async throws -> AppServerProcessChannels {
        self.executableURL = executableURL
        self.arguments = arguments
        return AppServerProcessChannels(
            standardInput: inputPipe.fileHandleForWriting,
            standardOutput: outputPipe.fileHandleForReading
        )
    }

    func terminate() async { terminateCount += 1; try? outputPipe.fileHandleForWriting.close() }
    func waitUntilExit() async { waitCount += 1 }
    func writeOutput(_ data: Data) throws { try outputPipe.fileHandleForWriting.write(contentsOf: data) }
}

private actor BlockingLineWriter: AppServerLineWriter {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private(set) var stopCount = 0

    func send(_ data: Data) async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        try await withCheckedThrowingContinuation { writeContinuation = $0 }
    }

    func stop() async {
        stopCount += 1
        writeContinuation?.resume(throwing: AppServerClientError.disconnected)
        writeContinuation = nil
    }

    func waitUntilWriteStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private final class BufferReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    var values: [Int] { lock.withLock { storage } }
    func record(_ value: Int) { lock.withLock { storage.append(value) } }
}

private struct FixedExecutableResolver: CodexExecutableResolving {
    let executable: URL
    init(_ executable: URL) { self.executable = executable }
    func resolve() throws -> URL { executable }
}

private struct FakeExecutableFiles: ExecutableFileChecking {
    let executables: Set<String>
    let regularFiles: Set<String>
    init(executables: Set<String> = [], regularFiles: Set<String>? = nil) { self.executables = executables; self.regularFiles = regularFiles ?? executables }
    func resolvedPath(_ path: String) -> String { path }
    func isExecutableFile(atPath path: String) -> Bool { executables.contains(path) }
    func isRegularFile(atPath path: String) -> Bool { regularFiles.contains(path) }
}

private extension AsyncStream where Element == AccountRateLimitsUpdatedNotification {
    func firstValue() async throws -> Element {
        for await value in self { return value }
        throw AppServerClientError.disconnected
    }
    func collectToEnd() async -> [Element] {
        var values: [Element] = []
        for await value in self { values.append(value) }
        return values
    }
}
