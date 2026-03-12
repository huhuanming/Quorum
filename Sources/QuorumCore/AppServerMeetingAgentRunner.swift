import Foundation

enum AppServerMeetingAgentRunnerError: LocalizedError {
    case providerNotSupported(String)
    case executableNotFound(String)
    case turnDidNotComplete(String)
    case turnFailed(String)
    case emptyResponse(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .providerNotSupported(let provider):
            return "Provider is not supported by app-server runner: \(provider)"
        case .executableNotFound(let hint):
            return "Agent executable was not found. \(hint)"
        case .turnDidNotComplete(let alias):
            return "Agent turn did not complete for alias: \(alias)"
        case .turnFailed(let status):
            return "Agent turn completed with non-success status: \(status)"
        case .emptyResponse(let alias):
            return "Agent produced empty response for alias: \(alias)"
        case .timedOut(let alias):
            return "Agent turn timed out for alias: \(alias)"
        }
    }
}

struct ResolvedAgentExecutable: Sendable {
    let executable: String
    let source: String
}

enum AppServerMeetingAgentRunner {
    static func run(participant: Participant, context: AgentTurnContext) async throws -> String {
        let provider = participant.provider.lowercased()
        guard provider != "human" else {
            throw AppServerMeetingAgentRunnerError.providerNotSupported(provider)
        }

        guard let resolved = resolveExecutable(for: provider) else {
            // Fallback to an explicit message so meeting flow still works even when local adapter is missing.
            return "[\(participant.alias)] agent executable missing for provider '\(provider)'. Configure env and retry."
        }

        let cwd = FileManager.default.currentDirectoryPath
        let client = AppServerJSONRPCClient(cwd: cwd, executable: resolved.executable)
        let accumulator = AppServerStreamAccumulator()

        await client.setEventHandler { event in
            switch event {
            case .agentMessageDelta(_, let delta):
                await accumulator.appendDelta(delta)
            case .agentMessageCompleted(let phase, let text):
                if phase == "final_answer" {
                    await accumulator.setFinalAnswer(text)
                }
            case .commandOutputDelta(_, _):
                break
            case .diagnostic(_):
                break
            case .turnCompleted(_, _):
                break
            case .turnStarted(_):
                break
            case .threadStarted(_):
                break
            case .processTerminated(_):
                break
            }
        }

        do {
            try await client.connect()
            let developerInstructions = buildDeveloperInstructions(for: participant)
            let threadID = try await client.startThread(
                model: participant.model,
                developerInstructions: developerInstructions,
                approvalPolicy: "never",
                sandbox: "danger-full-access"
            )
            let turnID = try await client.startTurn(threadId: threadID, input: context.prompt)
            let status = try await waitTurnWithTimeout(client: client, turnID: turnID, timeoutSeconds: 120)
            let outputBuffer = await accumulator.buffer
            let finalAnswer = await accumulator.finalAnswer
            await client.shutdown()

            guard status == "completed" else {
                throw AppServerMeetingAgentRunnerError.turnFailed(status)
            }

            let trimmedFinal = finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedFinal.isEmpty {
                return trimmedFinal
            }
            let trimmedBuffer = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedBuffer.isEmpty else {
                throw AppServerMeetingAgentRunnerError.emptyResponse(participant.alias)
            }
            return trimmedBuffer
        } catch {
            await client.shutdown()
            // Degrade gracefully instead of breaking the whole room.
            return "[\(participant.alias)] agent execution failed: \(error.localizedDescription)"
        }
    }

    private static func waitTurnWithTimeout(
        client: AppServerJSONRPCClient,
        turnID: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await client.waitForTurnCompletion(turnId: turnID)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppServerMeetingAgentRunnerError.timedOut(turnID)
            }

            guard let first = try await group.next() else {
                throw AppServerMeetingAgentRunnerError.turnDidNotComplete(turnID)
            }
            group.cancelAll()
            return first
        }
    }

    private static func buildDeveloperInstructions(for participant: Participant) -> String {
        let roles = participant.roles.map(\.rawValue).joined(separator: ", ")
        return """
        You are a participant in a multi-agent technical meeting.
        Alias: \(participant.alias)
        Provider: \(participant.provider)
        Model: \(participant.model)
        Active roles: \(roles)

        Always respond with one concise chat message appropriate for your role.
        If and only if you are acting as judge, include:
        decision: continue|converge|terminate
        """
    }

    private static func resolveExecutable(for provider: String) -> ResolvedAgentExecutable? {
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()

        let envKey: String
        let fallback: String
        switch provider {
        case "codex":
            envKey = "MEET_AGENT_EXECUTABLE_CODEX"
            fallback = "codex"
        case "claude":
            envKey = "MEET_AGENT_EXECUTABLE_CLAUDE"
            fallback = "\(home)/.meeting/agents/claude-adapter"
        case "kimi":
            envKey = "MEET_AGENT_EXECUTABLE_KIMI"
            fallback = "\(home)/.meeting/agents/kimi-adapter"
        default:
            envKey = "MEET_AGENT_EXECUTABLE_CUSTOM"
            fallback = provider
        }

        if let configured = environment[envKey], let resolved = resolvePath(configured) {
            return ResolvedAgentExecutable(executable: resolved, source: "env:\(envKey)")
        }
        if let resolved = resolvePath(fallback) {
            return ResolvedAgentExecutable(executable: resolved, source: "default")
        }
        return nil
    }

    private static func resolvePath(_ candidate: String) -> String? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let expanded = expandPath(trimmed)
        if expanded.contains("/") {
            return isExecutable(path: expanded) ? expanded : nil
        }

        let environment = ProcessInfo.processInfo.environment
        var paths: [String] = []
        if let rawPath = environment["PATH"], !rawPath.isEmpty {
            paths.append(contentsOf: rawPath.split(separator: ":").map(String.init))
        }
        paths.append(contentsOf: [
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ])

        var seen = Set<String>()
        for directory in paths {
            let expandedDirectory = expandPath(directory)
            guard seen.insert(expandedDirectory).inserted else { continue }
            let path = URL(fileURLWithPath: expandedDirectory).appendingPathComponent(expanded).path
            if isExecutable(path: path) {
                return path
            }
        }
        return nil
    }

    private static func expandPath(_ rawPath: String) -> String {
        if rawPath.hasPrefix("~/") {
            return NSHomeDirectory() + "/" + rawPath.dropFirst(2)
        }
        return rawPath
    }

    private static func isExecutable(path: String) -> Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: path)
    }
}

private enum AppServerEvent: Sendable {
    case threadStarted(threadId: String)
    case turnStarted(turnId: String)
    case turnCompleted(turnId: String, status: String)
    case processTerminated(exitCode: Int32)
    case agentMessageDelta(itemId: String, delta: String)
    case commandOutputDelta(itemId: String, delta: String)
    case agentMessageCompleted(phase: String?, text: String)
    case diagnostic(String)
}

private actor AppServerStreamAccumulator {
    var buffer: String = ""
    var finalAnswer: String = ""

    func appendDelta(_ delta: String) {
        buffer += delta
    }

    func setFinalAnswer(_ text: String) {
        finalAnswer = text
    }
}

private enum AppServerJSONRPCClientError: LocalizedError {
    case processNotRunning
    case invalidResponse(String)
    case responseError(String)
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "App-server process is not running."
        case .invalidResponse(let line):
            return "Invalid response from app-server: \(line)"
        case .responseError(let message):
            return "App-server returned an error: \(message)"
        case .missingField(let field):
            return "App-server response missing field: \(field)"
        }
    }
}

private actor AppServerJSONRPCClient {
    typealias EventHandler = @Sendable (AppServerEvent) async -> Void

    private let cwd: String
    private let executable: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var nextRequestID = 1
    private var pendingResponses: [String: CheckedContinuation<Data, Error>] = [:]
    private var pendingTurnCompletions: [String: CheckedContinuation<String, Error>] = [:]
    private var completedTurns: [String: String] = [:]
    private var eventHandler: EventHandler?
    private var isClosed = false

    init(cwd: String, executable: String) {
        self.cwd = cwd
        self.executable = executable
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    func connect() async throws {
        guard process == nil else { return }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "app-server", "--listen", "stdio://"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.terminationHandler = { [weak self] proc in
            Task {
                await self?.handleTermination(exitCode: proc.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        self.isClosed = false

        startReadTasks(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        _ = try await sendRequest(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "quorum",
                    "version": "0.1.0",
                ],
                "capabilities": [
                    "experimentalApi": true,
                ],
            ]
        )
        try sendNotification(method: "initialized", params: nil)
    }

    func startThread(
        model: String?,
        developerInstructions: String?,
        approvalPolicy: String,
        sandbox: String
    ) async throws -> String {
        var params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": approvalPolicy,
            "sandbox": sandbox,
        ]
        if let model, !model.isEmpty {
            params["model"] = model
        }
        if let developerInstructions, !developerInstructions.isEmpty {
            params["developerInstructions"] = developerInstructions
        }

        let result = try await sendRequest(method: "thread/start", params: params)
        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String
        else {
            throw AppServerJSONRPCClientError.missingField("thread.id")
        }
        return threadID
    }

    func startTurn(threadId: String, input: String) async throws -> String {
        let result = try await sendRequest(
            method: "turn/start",
            params: [
                "threadId": threadId,
                "input": [
                    [
                        "type": "text",
                        "text": input,
                    ],
                ],
            ]
        )
        guard let turn = result["turn"] as? [String: Any],
              let turnID = turn["id"] as? String
        else {
            throw AppServerJSONRPCClientError.missingField("turn.id")
        }
        return turnID
    }

    func waitForTurnCompletion(turnId: String) async throws -> String {
        if let completed = completedTurns.removeValue(forKey: turnId) {
            return completed
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingTurnCompletions[turnId] = continuation
        }
    }

    func shutdown() async {
        guard !isClosed else { return }
        isClosed = true

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let process, process.isRunning {
            process.terminate()
        }

        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil

        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: AppServerJSONRPCClientError.processNotRunning)
        }
        pendingResponses.removeAll()

        for (_, continuation) in pendingTurnCompletions {
            continuation.resume(throwing: AppServerJSONRPCClientError.processNotRunning)
        }
        pendingTurnCompletions.removeAll()
        completedTurns.removeAll()
    }

    // MARK: - Event and IO handling

    private func startReadTasks(stdoutPipe: Pipe, stderrPipe: Pipe) {
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task {
                await self.handleStdoutChunk(data)
            }
        }

        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task {
                await self.handleStderrChunk(data)
            }
        }
    }

    private func handleStdoutChunk(_ data: Data) async {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            var lineData = stdoutBuffer.prefix(upTo: newlineIndex)
            stdoutBuffer.removeSubrange(...newlineIndex)
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                emit(.diagnostic("app-server stdout decode error"))
                continue
            }
            await handleStdoutLine(line)
        }
    }

    private func handleStderrChunk(_ data: Data) async {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        while let newlineIndex = stderrBuffer.firstIndex(of: 0x0A) {
            var lineData = stderrBuffer.prefix(upTo: newlineIndex)
            stderrBuffer.removeSubrange(...newlineIndex)
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            guard let line = String(data: lineData, encoding: .utf8) else {
                emit(.diagnostic("app-server stderr decode error"))
                continue
            }
            emit(.diagnostic("app-server: \(line)"))
        }
    }

    private func handleStdoutLine(_ line: String) async {
        guard !line.isEmpty else { return }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any]
        else {
            emit(.diagnostic("unparsed line: \(line)"))
            return
        }

        if let id = stringValue(dictionary["id"]) {
            guard let continuation = pendingResponses.removeValue(forKey: id) else {
                return
            }
            if let errorDict = dictionary["error"] as? [String: Any] {
                let message = errorDict["message"] as? String ?? "Unknown error"
                continuation.resume(throwing: AppServerJSONRPCClientError.responseError(message))
                return
            }
            if let result = dictionary["result"] as? [String: Any] {
                let resultData = (try? JSONSerialization.data(withJSONObject: result, options: [])) ?? Data("{}".utf8)
                continuation.resume(returning: resultData)
                return
            }
            continuation.resume(returning: Data("{}".utf8))
            return
        }

        guard let method = dictionary["method"] as? String else { return }
        let params = dictionary["params"] as? [String: Any] ?? [:]
        await handleNotification(method: method, params: params)
    }

    private func handleNotification(method: String, params: [String: Any]) async {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let threadID = thread["id"] as? String
            {
                emit(.threadStarted(threadId: threadID))
            }

        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String
            {
                emit(.turnStarted(turnId: turnID))
            }

        case "turn/completed":
            if let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String,
               let status = turn["status"] as? String
            {
                if let continuation = pendingTurnCompletions.removeValue(forKey: turnID) {
                    continuation.resume(returning: status)
                } else {
                    completedTurns[turnID] = status
                }
                emit(.turnCompleted(turnId: turnID, status: status))
            }

        case "item/agentMessage/delta":
            if let itemID = params["itemId"] as? String,
               let delta = params["delta"] as? String
            {
                emit(.agentMessageDelta(itemId: itemID, delta: delta))
            }

        case "item/commandExecution/outputDelta":
            if let itemID = params["itemId"] as? String,
               let delta = params["delta"] as? String
            {
                emit(.commandOutputDelta(itemId: itemID, delta: delta))
            }

        case "item/completed":
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String,
               type == "agentMessage"
            {
                let phase = item["phase"] as? String
                let text = item["text"] as? String ?? ""
                emit(.agentMessageCompleted(phase: phase, text: text))
            }

        default:
            break
        }
    }

    private func handleTermination(exitCode: Int32) {
        if isClosed { return }
        isClosed = true

        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: AppServerJSONRPCClientError.responseError("Process exited with code \(exitCode)"))
        }
        pendingResponses.removeAll()

        for (_, continuation) in pendingTurnCompletions {
            continuation.resume(throwing: AppServerJSONRPCClientError.responseError("Process exited with code \(exitCode)"))
        }
        pendingTurnCompletions.removeAll()

        emit(.processTerminated(exitCode: exitCode))
    }

    // MARK: - JSON-RPC

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard process != nil, !isClosed else { throw AppServerJSONRPCClientError.processNotRunning }

        let requestID = String(nextRequestID)
        nextRequestID += 1

        try writeJSON([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ])

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = continuation
        }

        guard let object = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String: Any] else {
            throw AppServerJSONRPCClientError.invalidResponse(String(data: responseData, encoding: .utf8) ?? "<binary>")
        }
        return object
    }

    private func sendNotification(method: String, params: [String: Any]?) throws {
        guard process != nil, !isClosed else { throw AppServerJSONRPCClientError.processNotRunning }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            payload["params"] = params
        }
        try writeJSON(payload)
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard let stdinPipe else { throw AppServerJSONRPCClientError.processNotRunning }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func emit(_ event: AppServerEvent) {
        guard let eventHandler else { return }
        Task {
            await eventHandler(event)
        }
    }
}
