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
    actor Session {
        private let participant: Participant
        private let provider: String
        private let resolved: ResolvedAgentExecutable?
        private let cwd: String

        private var client: AppServerJSONRPCClient?
        private var threadID: String?

        init(
            participant: Participant,
            cwd: String = FileManager.default.currentDirectoryPath
        ) {
            self.participant = participant
            self.provider = participant.provider.lowercased()
            self.resolved = AppServerMeetingAgentRunner.resolveExecutable(for: participant.provider.lowercased())
            self.cwd = cwd
        }

        func generateReply(context: AgentTurnContext) async throws -> AgentReplyOutput {
            guard provider != "human" else {
                throw AppServerMeetingAgentRunnerError.providerNotSupported(provider)
            }
            guard let resolved else {
                return AgentReplyOutput(
                    content: "[\(participant.alias)] agent executable missing for provider '\(provider)'. Configure env and retry.",
                    status: "failed: executable_missing",
                    diagnostics: ["provider=\(provider) executable_source=missing"]
                )
            }

            let maxAttempts = 3
            var recentDiagnostics: [String] = []

            for attempt in 1 ... maxAttempts {
                let accumulator = AppServerStreamAccumulator()
                do {
                    let client = try await ensureConnectedClient(executable: resolved.executable)
                    guard await client.isProcessRunning() else {
                        throw AppServerJSONRPCClientError.processNotRunning
                    }
                    await client.setEventHandler { event in
                        await AppServerMeetingAgentRunner.forward(event: event, to: accumulator)
                    }

                    let threadID = try await ensureThreadID(client: client)
                    let turnID = try await client.startTurn(
                        threadId: threadID,
                        input: context.prompt,
                        effort: AppServerMeetingAgentRunner.preferredReasoningEffort(for: participant)
                    )
                    let status = try await AppServerMeetingAgentRunner.waitTurnWithTimeout(
                        client: client,
                        turnID: turnID,
                        alias: participant.alias,
                        timeoutSeconds: 45
                    )
                    return try await AppServerMeetingAgentRunner.buildOutput(
                        participant: participant,
                        provider: provider,
                        resolved: resolved,
                        status: status,
                        accumulator: accumulator
                    )
                } catch {
                    let attemptDiagnostics = await accumulator.diagnostics
                    recentDiagnostics.append(contentsOf: attemptDiagnostics)
                    recentDiagnostics.append("attempt=\(attempt) error=\(error.localizedDescription)")
                    let recoverable = AppServerMeetingAgentRunner.shouldRetry(error: error)
                    await resetTransport()
                    if recoverable && attempt < maxAttempts {
                        let backoffMs = 200 * Int(pow(2.0, Double(attempt - 1)))
                        recentDiagnostics.append("attempt=\(attempt) retry_in_ms=\(backoffMs)")
                        try? await Task.sleep(nanoseconds: UInt64(backoffMs) * 1_000_000)
                        continue
                    }

                    var diagnostics = recentDiagnostics
                    diagnostics.insert("provider=\(provider) executable=\(resolved.executable) source=\(resolved.source)", at: 0)
                    diagnostics.append("error=\(error.localizedDescription)")
                    return AgentReplyOutput(
                        content: "[\(participant.alias)] agent execution failed: \(error.localizedDescription)",
                        status: "failed",
                        diagnostics: diagnostics
                    )
                }
            }

            return AgentReplyOutput(
                content: "[\(participant.alias)] agent execution failed: retry attempts exhausted",
                status: "failed",
                diagnostics: ["provider=\(provider) executable=\(resolved.executable) source=\(resolved.source)"]
            )
        }

        func shutdown() async {
            await resetTransport()
        }

        private func ensureConnectedClient(executable: String) async throws -> AppServerJSONRPCClient {
            if let client {
                return client
            }
            let created = AppServerJSONRPCClient(cwd: cwd, executable: executable)
            try await created.connect()
            client = created
            return created
        }

        private func ensureThreadID(client: AppServerJSONRPCClient) async throws -> String {
            if let threadID {
                return threadID
            }
            let developerInstructions = AppServerMeetingAgentRunner.buildDeveloperInstructions(for: participant)
            let createdThreadID = try await client.startThread(
                model: participant.model,
                developerInstructions: developerInstructions,
                approvalPolicy: "never",
                sandbox: "danger-full-access"
            )
            threadID = createdThreadID
            return createdThreadID
        }

        private func resetTransport() async {
            if let client {
                await client.shutdown()
            }
            client = nil
            threadID = nil
        }
    }

    static func run(participant: Participant, context: AgentTurnContext) async throws -> AgentReplyOutput {
        let session = Session(participant: participant)
        let output = try await session.generateReply(context: context)
        await session.shutdown()
        return output
    }

    private static func forward(
        event: AppServerEvent,
        to accumulator: AppServerStreamAccumulator
    ) async {
        switch event {
        case .agentMessageDelta(_, let delta):
            await accumulator.appendDelta(delta)
        case .agentMessageCompleted(let phase, let text):
            if phase == "final_answer" {
                await accumulator.setFinalAnswer(text)
            }
        case .commandOutputDelta(_, let delta):
            await accumulator.appendDiagnostic("command-output: \(delta)")
        case .diagnostic(let message):
            await accumulator.appendDiagnostic(message)
        case .turnCompleted(let turnId, let status):
            await accumulator.appendDiagnostic("turn-completed turn_id=\(turnId) status=\(status)")
        case .turnStarted(let turnId):
            await accumulator.appendDiagnostic("turn-started turn_id=\(turnId)")
        case .threadStarted(let threadId):
            await accumulator.appendDiagnostic("thread-started thread_id=\(threadId)")
        case .processTerminated(let exitCode):
            await accumulator.appendDiagnostic("process-terminated exit_code=\(exitCode)")
        }
    }

    private static func buildOutput(
        participant: Participant,
        provider: String,
        resolved: ResolvedAgentExecutable,
        status: String,
        accumulator: AppServerStreamAccumulator
    ) async throws -> AgentReplyOutput {
        let outputBuffer = await accumulator.buffer
        let finalAnswer = await accumulator.finalAnswer
        var diagnostics = await accumulator.diagnostics
        diagnostics.insert("provider=\(provider) executable=\(resolved.executable) source=\(resolved.source)", at: 0)

        guard status == "completed" else {
            throw AppServerMeetingAgentRunnerError.turnFailed(status)
        }

        let trimmedFinal = finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFinal.isEmpty {
            return AgentReplyOutput(content: trimmedFinal, status: status, diagnostics: diagnostics)
        }
        let trimmedBuffer = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBuffer.isEmpty else {
            throw AppServerMeetingAgentRunnerError.emptyResponse(participant.alias)
        }
        return AgentReplyOutput(content: trimmedBuffer, status: status, diagnostics: diagnostics)
    }

    private static func waitTurnWithTimeout(
        client: AppServerJSONRPCClient,
        turnID: String,
        alias: String,
        timeoutSeconds: TimeInterval
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await client.waitForTurnCompletion(turnId: turnID)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppServerMeetingAgentRunnerError.timedOut(alias)
            }

            guard let first = try await group.next() else {
                throw AppServerMeetingAgentRunnerError.turnDidNotComplete(turnID)
            }
            group.cancelAll()
            return first
        }
    }

    private static func shouldRetry(error: Error) -> Bool {
        if let runnerError = error as? AppServerMeetingAgentRunnerError {
            switch runnerError {
            case .timedOut, .turnDidNotComplete:
                return true
            case .providerNotSupported, .executableNotFound, .turnFailed, .emptyResponse:
                return false
            }
        }
        if let rpcError = error as? AppServerJSONRPCClientError {
            switch rpcError {
            case .processNotRunning:
                return true
            case .responseError(let message):
                let lowered = message.lowercased()
                return lowered.contains("process exited") || lowered.contains("timed out")
            case .invalidResponse, .missingField:
                return false
            }
        }
        if error is CancellationError {
            return true
        }
        return false
    }

    private static func preferredReasoningEffort(for participant: Participant) -> String? {
        guard participant.provider.caseInsensitiveCompare("codex") == .orderedSame else {
            return nil
        }
        // ChatGPT-backed codex sessions can default to xhigh, which fails on some models (for example gpt-5).
        return "high"
    }

    private static func buildDeveloperInstructions(for participant: Participant) -> String {
        let roles = participant.roles.map(\.rawValue).joined(separator: ", ")
        let roleGuidance: String
        if participant.roles.contains(.planner) {
            roleGuidance = """
            Planner duties:
            - Produce implementation plan and concrete artifact when ready.
            - If status=done, artifact_path must be absolute and point to the latest planner deliverable.
            - Never retask objective by yourself; ask host for retask.
            """
        } else if participant.roles.contains(.reviewer) {
            roleGuidance = """
            Reviewer duties:
            - Review latest planner deliverable, call out defects and regressions.
            - If no fresh planner artifact exists, use status=blocked with reason=waiting_for_input.
            - Keep output focused on verification evidence and actionable changes.
            """
        } else if participant.roles.contains(.judge) {
            roleGuidance = """
            Judge duties:
            - Decide only after planner/reviewer progress exists, unless host explicitly requests a decision.
            - Use decision marker only when acting as judge.
            """
        } else {
            roleGuidance = "General duties: provide concise, objective-aligned progress updates."
        }

        return """
        You are a participant in a multi-agent technical meeting.
        Alias: \(participant.alias)
        Provider: \(participant.provider)
        Model: \(participant.model)
        Active roles: \(roles)

        Keep your reply concise and objective-aligned.
        \(roleGuidance)
        The first line must follow transcript format: 「角色名称」：「说话」.
        Only host directives can redefine objective or deliverable scope.
        Host retask syntax is explicit: objective:..., deliverable:..., constraints:...
        Append footer lines exactly:
        status: progress|blocked|done
        artifact_path: /absolute/path|(none)
        reason: <short sentence>
        Do not include markdown fences.
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
    var diagnostics: [String] = []

    func appendDelta(_ delta: String) {
        buffer += delta
    }

    func setFinalAnswer(_ text: String) {
        finalAnswer = text
    }

    func appendDiagnostic(_ text: String) {
        diagnostics.append(text)
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

    func isProcessRunning() -> Bool {
        guard let process else { return false }
        return !isClosed && process.isRunning
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

    func startTurn(threadId: String, input: String, effort: String? = nil) async throws -> String {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": [
                [
                    "type": "text",
                    "text": input,
                ],
            ],
        ]
        if let effort, !effort.isEmpty {
            params["effort"] = effort
        }

        let result = try await sendRequest(
            method: "turn/start",
            params: params
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
            if let errorDict = dictionary["error"] as? [String: Any] {
                let errorMessage = (errorDict["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                emit(.diagnostic("rpc<- response id=\(id) error=\(errorMessage)"))
            } else if let result = dictionary["result"] as? [String: Any] {
                let summary = summarizeIncomingResponse(result: result)
                emit(.diagnostic("rpc<- response id=\(id) result \(summary)"))
            } else {
                emit(.diagnostic("rpc<- response id=\(id) result {}"))
            }

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
        emit(.diagnostic("rpc<- notify method=\(method) \(summarizeIncomingNotification(method: method, params: params))"))
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
                let errorMessage = turnErrorMessage(from: turn["error"])
                let completionStatus = statusWithError(status: status, errorMessage: errorMessage)
                if let continuation = pendingTurnCompletions.removeValue(forKey: turnID) {
                    continuation.resume(returning: completionStatus)
                } else {
                    completedTurns[turnID] = completionStatus
                }
                emit(.turnCompleted(turnId: turnID, status: completionStatus))
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

        emit(.diagnostic("rpc-> request id=\(requestID) method=\(method) \(summarizeOutgoingRequest(method: method, params: params))"))

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
        let summary = params.map { summarizeOutgoingRequest(method: method, params: $0) } ?? ""
        emit(.diagnostic("rpc-> notify method=\(method) \(summary)"))
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

    private func turnErrorMessage(from value: Any?) -> String? {
        if let message = value as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let dictionary = value as? [String: Any] else {
            return nil
        }
        if let message = dictionary["message"] as? String {
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let details = dictionary["details"] as? String {
            let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let serialized = try? JSONSerialization.data(withJSONObject: dictionary, options: []),
           let text = String(data: serialized, encoding: .utf8)
        {
            return text
        }
        return nil
    }

    private func statusWithError(status: String, errorMessage: String?) -> String {
        guard status != "completed", let errorMessage, !errorMessage.isEmpty else {
            return status
        }
        return "\(status): \(errorMessage)"
    }

    private func summarizeOutgoingRequest(method: String, params: [String: Any]) -> String {
        switch method {
        case "thread/start":
            let model = (params["model"] as? String) ?? "(default)"
            let approval = (params["approvalPolicy"] as? String) ?? "(unset)"
            let sandbox = (params["sandbox"] as? String) ?? "(unset)"
            return "model=\(model) approval=\(approval) sandbox=\(sandbox)"
        case "turn/start":
            let threadID = (params["threadId"] as? String) ?? "(missing)"
            let effort = (params["effort"] as? String) ?? "(default)"
            let preview = previewTurnInput(params)
            return "thread_id=\(threadID) effort=\(effort) input=\(preview)"
        default:
            return ""
        }
    }

    private func summarizeIncomingResponse(result: [String: Any]) -> String {
        if let thread = result["thread"] as? [String: Any],
           let threadID = thread["id"] as? String
        {
            return "thread_id=\(threadID)"
        }
        if let turn = result["turn"] as? [String: Any],
           let turnID = turn["id"] as? String
        {
            return "turn_id=\(turnID)"
        }
        if result.isEmpty {
            return "{}"
        }
        return "keys=\(result.keys.sorted().joined(separator: ","))"
    }

    private func summarizeIncomingNotification(method: String, params: [String: Any]) -> String {
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any],
               let threadID = thread["id"] as? String
            {
                return "thread_id=\(threadID)"
            }
        case "turn/started":
            if let turn = params["turn"] as? [String: Any],
               let turnID = turn["id"] as? String
            {
                return "turn_id=\(turnID)"
            }
        case "turn/completed":
            if let turn = params["turn"] as? [String: Any] {
                let turnID = (turn["id"] as? String) ?? "(unknown)"
                let status = (turn["status"] as? String) ?? "(unknown)"
                return "turn_id=\(turnID) status=\(status)"
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               let type = item["type"] as? String
            {
                if type == "agentMessage" {
                    let phase = (item["phase"] as? String) ?? "(none)"
                    let text = (item["text"] as? String) ?? ""
                    return "type=agentMessage phase=\(phase) text=\(preview(text, limit: 180))"
                }
                return "type=\(type)"
            }
        case "item/commandExecution/outputDelta":
            if let delta = params["delta"] as? String {
                return "delta=\(preview(delta, limit: 120))"
            }
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                return "delta=\(preview(delta, limit: 120))"
            }
        default:
            break
        }
        return ""
    }

    private func previewTurnInput(_ params: [String: Any]) -> String {
        guard let input = params["input"] as? [Any],
              let first = input.first as? [String: Any],
              let text = first["text"] as? String
        else {
            return "(none)"
        }
        return preview(text, limit: 240)
    }

    private func preview(_ rawText: String, limit: Int) -> String {
        let flattened = rawText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit, limit > 0 else {
            return flattened
        }
        let endIndex = flattened.index(flattened.startIndex, offsetBy: limit)
        return String(flattened[..<endIndex]) + "..."
    }

    private func emit(_ event: AppServerEvent) {
        guard let eventHandler else { return }
        Task {
            await eventHandler(event)
        }
    }
}
