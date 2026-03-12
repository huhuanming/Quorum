import Foundation

public struct AgentTurnContext: Sendable {
    public var meeting: Meeting
    public var participant: Participant
    public var lastMessages: [MeetingMessage]
    public var attachments: [MeetingAttachment]
    public var prompt: String

    public init(
        meeting: Meeting,
        participant: Participant,
        lastMessages: [MeetingMessage],
        attachments: [MeetingAttachment],
        prompt: String
    ) {
        self.meeting = meeting
        self.participant = participant
        self.lastMessages = lastMessages
        self.attachments = attachments
        self.prompt = prompt
    }
}

public struct AgentReplyOutput: Sendable {
    public var content: String
    public var status: String
    public var diagnostics: [String]

    public init(content: String, status: String = "completed", diagnostics: [String] = []) {
        self.content = content
        self.status = status
        self.diagnostics = diagnostics
    }
}

public struct MeetingAgentClient: Sendable {
    public var alias: String
    public var provider: String
    public var model: String
    private let generateReplyClosure: @Sendable (AgentTurnContext) async throws -> AgentReplyOutput
    private let shutdownClosure: @Sendable () async -> Void

    public init(
        alias: String,
        provider: String,
        model: String,
        generateReply: @escaping @Sendable (AgentTurnContext) async throws -> AgentReplyOutput,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.alias = alias
        self.provider = provider
        self.model = model
        self.generateReplyClosure = generateReply
        self.shutdownClosure = shutdown
    }

    public func generateReply(context: AgentTurnContext) async throws -> AgentReplyOutput {
        try await generateReplyClosure(context)
    }

    public func shutdown() async {
        await shutdownClosure()
    }
}

public struct MeetingAgentFactory: Sendable {
    public let makeClient: @Sendable (_ participant: Participant, _ meeting: Meeting) async throws -> MeetingAgentClient

    public init(
        _ makeClient: @escaping @Sendable (_ participant: Participant, _ meeting: Meeting) async throws -> MeetingAgentClient
    ) {
        self.makeClient = makeClient
    }

    public static let appServer = MeetingAgentFactory { participant, _ in
        MeetingAgentClient(
            alias: participant.alias,
            provider: participant.provider,
            model: participant.model,
            generateReply: { context in
                try await AppServerMeetingAgentRunner.run(
                    participant: participant,
                    context: context
                )
            },
            shutdown: {}
        )
    }
}

public enum MeetingOrchestratorError: Error, LocalizedError, Equatable {
    case meetingNotRunning(UUID)
    case noAgentParticipants(UUID)
    case agentClientMissing(String)
    case emptyAgentReply(String)
    case autopilotAlreadyRunning(UUID)

    public var errorDescription: String? {
        switch self {
        case .meetingNotRunning(let id):
            return "Meeting is not running: \(id.uuidString.lowercased())"
        case .noAgentParticipants(let id):
            return "No non-human agent participant is available in meeting: \(id.uuidString.lowercased())"
        case .agentClientMissing(let alias):
            return "Agent client not found for alias: \(alias)"
        case .emptyAgentReply(let alias):
            return "Agent returned empty reply: \(alias)"
        case .autopilotAlreadyRunning(let id):
            return "Autopilot is already running for meeting: \(id.uuidString.lowercased())"
        }
    }
}

public actor MeetingOrchestrator {
    private struct RoomState {
        var clients: [String: MeetingAgentClient] = [:]
        var speakerOrder: [String] = []
        var regularSpeakerOrder: [String] = []
        var judgeSpeakerOrder: [String] = []
        var nextSpeakerIndex: Int = 0
        var nextRegularSpeakerIndex: Int = 0
        var nextJudgeSpeakerIndex: Int = 0
        var judgeGatedExpectJudgeNext: Bool = false
        var lastPolicyMode: MeetingSpeakingMode?
        var autopilotTask: Task<Void, Never>?
    }

    private let runtime: MeetingRuntime
    private let factory: MeetingAgentFactory
    private let now: @Sendable () -> Date
    private var rooms: [UUID: RoomState] = [:]

    public init(
        runtime: MeetingRuntime,
        factory: MeetingAgentFactory = .appServer,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runtime = runtime
        self.factory = factory
        self.now = now
    }

    @discardableResult
    public func tick(meetingID: UUID) async throws -> MeetingMessage {
        let meeting = try await runtime.meeting(id: meetingID)
        guard meeting.phase == .running else {
            throw MeetingOrchestratorError.meetingNotRunning(meetingID)
        }

        var roomState = try await hydrateRoomState(meeting: meeting)
        let speakerAlias = try nextSpeakerAlias(state: &roomState, meeting: meeting)
        guard let participant = meeting.participants.first(where: {
            $0.alias.caseInsensitiveCompare(speakerAlias) == .orderedSame
        }) else {
            throw MeetingOrchestratorError.agentClientMissing(speakerAlias)
        }

        guard let client = roomState.clients[speakerAlias.lowercased()] else {
            throw MeetingOrchestratorError.agentClientMissing(speakerAlias)
        }

        let context = buildContext(meeting: meeting, participant: participant)
        let startLog = AgentExecutionLog(
            participantAlias: participant.alias,
            participantDisplayName: participant.displayName,
            participantRole: participant.primaryRole,
            provider: participant.provider,
            model: participant.model,
            prompt: context.prompt,
            response: "",
            status: "running",
            diagnostics: ["agent turn started"],
            createdAt: now()
        )
        _ = try? await runtime.recordExecutionLog(meetingID: meetingID, log: startLog)

        let output: AgentReplyOutput
        do {
            output = try await client.generateReply(context: context)
        } catch {
            let failedLog = AgentExecutionLog(
                participantAlias: participant.alias,
                participantDisplayName: participant.displayName,
                participantRole: participant.primaryRole,
                provider: participant.provider,
                model: participant.model,
                prompt: context.prompt,
                response: "",
                status: "failed",
                diagnostics: ["error=\(error.localizedDescription)"],
                createdAt: now()
            )
            _ = try? await runtime.recordExecutionLog(meetingID: meetingID, log: failedLog)
            throw error
        }
        let reply = output.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            let emptyLog = AgentExecutionLog(
                participantAlias: participant.alias,
                participantDisplayName: participant.displayName,
                participantRole: participant.primaryRole,
                provider: participant.provider,
                model: participant.model,
                prompt: context.prompt,
                response: output.content,
                status: "\(output.status): empty_reply",
                diagnostics: output.diagnostics,
                createdAt: now()
            )
            _ = try? await runtime.recordExecutionLog(meetingID: meetingID, log: emptyLog)
            throw MeetingOrchestratorError.emptyAgentReply(participant.alias)
        }

        let message = try await runtime.postMessage(
            meetingID: meetingID,
            fromAlias: participant.alias,
            toAliases: ["all"],
            content: reply,
            activeRole: participant.primaryRole
        )
        let executionLog = AgentExecutionLog(
            participantAlias: participant.alias,
            participantDisplayName: participant.displayName,
            participantRole: participant.primaryRole,
            provider: participant.provider,
            model: participant.model,
            prompt: context.prompt,
            response: reply,
            status: output.status,
            diagnostics: output.diagnostics,
            createdAt: now()
        )
        _ = try? await runtime.recordExecutionLog(meetingID: meetingID, log: executionLog)

        if participant.roles.contains(.judge),
           meeting.policy.judgeAutoDecision,
           let decision = parseJudgeDecision(reply)
        {
            _ = try await runtime.recordJudgeDecision(meetingID: meetingID, decision: decision)
            if decision == .terminate {
                _ = try await runtime.stopMeeting(id: meetingID, reason: .judgeTerminated)
            }
        }

        rooms[meetingID] = roomState
        return message
    }

    public func tick(meetingID: UUID, rounds: Int) async throws -> [MeetingMessage] {
        guard rounds > 0 else { return [] }
        var produced: [MeetingMessage] = []
        produced.reserveCapacity(rounds)
        for _ in 0 ..< rounds {
            let message = try await tick(meetingID: meetingID)
            produced.append(message)

            let latest = try await runtime.meeting(id: meetingID)
            if latest.phase != .running {
                break
            }
        }
        return produced
    }

    public func setAutopilot(
        meetingID: UUID,
        enabled: Bool,
        intervalMilliseconds: UInt64 = 1200
    ) async throws {
        if !enabled {
            var roomState = rooms[meetingID] ?? RoomState()
            roomState.autopilotTask?.cancel()
            roomState.autopilotTask = nil
            rooms[meetingID] = roomState
            return
        }

        let meeting = try await runtime.meeting(id: meetingID)
        guard meeting.phase == .running else {
            throw MeetingOrchestratorError.meetingNotRunning(meetingID)
        }

        var roomState = try await hydrateRoomState(meeting: meeting)
        if enabled {
            if roomState.autopilotTask != nil {
                throw MeetingOrchestratorError.autopilotAlreadyRunning(meetingID)
            }

            let safeInterval = max(intervalMilliseconds, 25)
            roomState.autopilotTask = Task {
                await runAutopilotLoop(meetingID: meetingID, intervalMilliseconds: safeInterval)
            }
            rooms[meetingID] = roomState
            return
        }
    }

    public func autopilotEnabled(meetingID: UUID) -> Bool {
        rooms[meetingID]?.autopilotTask != nil
    }

    public func removeMeeting(meetingID: UUID) async {
        await stopRoom(roomID: meetingID)
    }

    public func stopAll() async {
        let roomIDs = Array(rooms.keys)
        for roomID in roomIDs {
            await stopRoom(roomID: roomID)
        }
    }

    private func runAutopilotLoop(meetingID: UUID, intervalMilliseconds: UInt64) async {
        let sleepNanos = intervalMilliseconds * 1_000_000
        while !Task.isCancelled {
            do {
                _ = try await tick(meetingID: meetingID)
            } catch MeetingOrchestratorError.meetingNotRunning {
                break
            } catch {
                break
            }

            do {
                try await Task.sleep(nanoseconds: sleepNanos)
            } catch {
                break
            }
        }

        var roomState = rooms[meetingID] ?? RoomState()
        roomState.autopilotTask = nil
        rooms[meetingID] = roomState
    }

    private func stopRoom(roomID: UUID) async {
        guard var roomState = rooms.removeValue(forKey: roomID) else { return }
        roomState.autopilotTask?.cancel()
        roomState.autopilotTask = nil
        for client in roomState.clients.values {
            await client.shutdown()
        }
    }

    private func hydrateRoomState(meeting: Meeting) async throws -> RoomState {
        var roomState = rooms[meeting.id] ?? RoomState()
        let agents = meeting.participants.filter { $0.provider.caseInsensitiveCompare("human") != .orderedSame }
        guard !agents.isEmpty else {
            throw MeetingOrchestratorError.noAgentParticipants(meeting.id)
        }

        let desiredAliases = agents.map {
            $0.alias.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
        }
        let desiredSet = Set(desiredAliases)

        let staleAliases = roomState.clients.keys.filter { !desiredSet.contains($0) }
        for alias in staleAliases {
            if let staleClient = roomState.clients.removeValue(forKey: alias) {
                await staleClient.shutdown()
            }
        }

        for agent in agents {
            let key = agent.alias.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased()
            if roomState.clients[key] == nil {
                let created = try await factory.makeClient(agent, meeting)
                roomState.clients[key] = created
            }
        }

        roomState.speakerOrder = desiredAliases
        roomState.regularSpeakerOrder = agents
            .filter { !$0.roles.contains(.judge) }
            .map { $0.alias.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased() }
        roomState.judgeSpeakerOrder = agents
            .filter { $0.roles.contains(.judge) }
            .map { $0.alias.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).lowercased() }

        if roomState.lastPolicyMode != meeting.policy.mode {
            roomState.judgeGatedExpectJudgeNext = false
            roomState.lastPolicyMode = meeting.policy.mode
        }

        if roomState.speakerOrder.isEmpty {
            throw MeetingOrchestratorError.noAgentParticipants(meeting.id)
        }
        if roomState.nextSpeakerIndex >= roomState.speakerOrder.count {
            roomState.nextSpeakerIndex = 0
        }
        if roomState.regularSpeakerOrder.isEmpty {
            roomState.nextRegularSpeakerIndex = 0
        } else if roomState.nextRegularSpeakerIndex >= roomState.regularSpeakerOrder.count {
            roomState.nextRegularSpeakerIndex = 0
        }
        if roomState.judgeSpeakerOrder.isEmpty {
            roomState.nextJudgeSpeakerIndex = 0
        } else if roomState.nextJudgeSpeakerIndex >= roomState.judgeSpeakerOrder.count {
            roomState.nextJudgeSpeakerIndex = 0
        }

        rooms[meeting.id] = roomState
        return roomState
    }

    private func nextSpeakerAlias(state: inout RoomState, meeting: Meeting) throws -> String {
        let meetingID = meeting.id
        if meeting.policy.mode == .judgeGated {
            let hasRegular = !state.regularSpeakerOrder.isEmpty
            let hasJudge = !state.judgeSpeakerOrder.isEmpty
            if hasRegular, hasJudge {
                if state.judgeGatedExpectJudgeNext {
                    let index = state.nextJudgeSpeakerIndex % state.judgeSpeakerOrder.count
                    let alias = state.judgeSpeakerOrder[index]
                    state.nextJudgeSpeakerIndex = (index + 1) % state.judgeSpeakerOrder.count
                    state.judgeGatedExpectJudgeNext = false
                    return alias
                }

                let index = state.nextRegularSpeakerIndex % state.regularSpeakerOrder.count
                let alias = state.regularSpeakerOrder[index]
                state.nextRegularSpeakerIndex = (index + 1) % state.regularSpeakerOrder.count
                state.judgeGatedExpectJudgeNext = true
                return alias
            }
        }

        return try nextRoundRobinSpeakerAlias(state: &state, meeting: meeting, meetingID: meetingID)
    }

    private func nextRoundRobinSpeakerAlias(state: inout RoomState, meeting: Meeting, meetingID: UUID) throws -> String {
        guard !state.speakerOrder.isEmpty else {
            throw MeetingOrchestratorError.noAgentParticipants(meetingID)
        }

        if state.nextSpeakerIndex == 0 {
            let aliasSet = Set(state.speakerOrder)
            if let lastAgentAlias = meeting.messages.reversed().compactMap({ message in
                let lowered = message.fromAlias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return aliasSet.contains(lowered) ? lowered : nil
            }).first,
               let lastIndex = state.speakerOrder.firstIndex(of: lastAgentAlias)
            {
                state.nextSpeakerIndex = (lastIndex + 1) % state.speakerOrder.count
            }
        }

        let index = state.nextSpeakerIndex % state.speakerOrder.count
        let alias = state.speakerOrder[index]
        state.nextSpeakerIndex = (index + 1) % state.speakerOrder.count
        return alias
    }

    private func buildContext(meeting: Meeting, participant: Participant) -> AgentTurnContext {
        let recentMessages = Array(meeting.messages.suffix(16))
        let prompt = buildPrompt(
            meeting: meeting,
            participant: participant,
            recentMessages: recentMessages,
            attachments: meeting.attachments
        )
        return AgentTurnContext(
            meeting: meeting,
            participant: participant,
            lastMessages: recentMessages,
            attachments: meeting.attachments,
            prompt: prompt
        )
    }

    private func buildPrompt(
        meeting: Meeting,
        participant: Participant,
        recentMessages: [MeetingMessage],
        attachments: [MeetingAttachment]
    ) -> String {
        var lines: [String] = []
        lines.append("You are participating in a multi-agent meeting.")
        lines.append("Current time: \(now().ISO8601Format())")
        lines.append("Meeting title: \(meeting.title)")
        lines.append("Meeting goal: \(meeting.goal)")
        lines.append("Your alias: \(participant.alias)")
        lines.append("Your model: \(participant.model)")
        let participantRoles = participant.roles.map(\.rawValue).joined(separator: ", ")
        lines.append("Your roles: \(participantRoles)")

        lines.append("Meeting default skill:")
        if let defaultSkill = meeting.defaultSkill {
            lines.append("- \(defaultSkill.name)")
            lines.append(defaultSkill.content)
        } else {
            lines.append("- (none)")
        }

        lines.append("Meeting additional skills:")
        if meeting.additionalSkills.isEmpty {
            lines.append("- (none)")
        } else {
            for skill in meeting.additionalSkills {
                lines.append("- \(skill.name)")
                lines.append(skill.content)
            }
        }

        lines.append("Your initial skill:")
        if let initialSkill = participant.initialSkill {
            lines.append("- \(initialSkill.name)")
            lines.append(initialSkill.content)
        } else {
            lines.append("- (none)")
        }

        lines.append("Participants:")
        for member in meeting.participants {
            let memberRoles = member.roles.map(\.rawValue).joined(separator: ",")
            lines.append("- @\(member.alias) [\(member.provider)/\(member.model)] roles=\(memberRoles)")
        }

        lines.append("Recent messages:")
        if recentMessages.isEmpty {
            lines.append("- (none)")
        } else {
            for message in recentMessages {
                let utterance = quotedUtterance(for: message, in: meeting)
                lines.append("- [\(message.createdAt.ISO8601Format())] \(utterance)")
            }
        }

        lines.append("Attachments:")
        if attachments.isEmpty {
            lines.append("- (none)")
        } else {
            for attachment in attachments {
                lines.append("- [\(attachment.kind.rawValue)] \(attachment.path)")
            }
        }

        lines.append("Instruction:")
        lines.append("- Reply with one concise meeting message in your role.")
        lines.append("- The conversation transcript format is strict: 「角色名称」：「说话」.")
        lines.append("- If you are acting as judge and the meeting can end, include exactly one decision marker:")
        lines.append("  decision: continue | decision: converge | decision: terminate")
        lines.append("- Do not include markdown fences.")
        return lines.joined(separator: "\n")
    }

    private func quotedUtterance(for message: MeetingMessage, in meeting: Meeting) -> String {
        let roleTitle: String
        if let role = message.activeRole {
            roleTitle = role.roleTitle
        } else if let participant = meeting.participants.first(where: {
            $0.alias.caseInsensitiveCompare(message.fromAlias) == .orderedSame
        }) {
            roleTitle = participant.primaryRole.roleTitle
        } else {
            roleTitle = "发言人"
        }
        let normalizedSpeech = message.content.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return "「\(roleTitle)」：「\(normalizedSpeech)」"
    }

    private func parseJudgeDecision(_ text: String) -> MeetingJudgeDecision? {
        let lowered = text.lowercased()
        if lowered.contains("decision: terminate") {
            return .terminate
        }
        if lowered.contains("decision: converge") {
            return .converge
        }
        if lowered.contains("decision: continue") {
            return .continue
        }
        return nil
    }
}

private extension ParticipantRole {
    var roleTitle: String {
        switch self {
        case .host:
            return "主持人"
        case .planner:
            return "规划师"
        case .reviewer:
            return "评审员"
        case .judge:
            return "裁判"
        case .observer:
            return "观察员"
        }
    }
}
