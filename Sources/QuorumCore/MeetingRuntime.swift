import Foundation

public actor MeetingRuntime {
    private struct TopicContractPatch {
        var objective: String?
        var deliverable: String?
        var constraints: [String]?

        var hasAnyField: Bool {
            objective != nil || deliverable != nil || constraints != nil
        }
    }

    private var meetings: [UUID: Meeting] = [:]
    private let participantLimit: ClosedRange<Int> = 3 ... 6
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let snapshotStore: SQLiteSnapshotStore?

    public init(
        databaseURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.now = now
        let resolvedDatabaseURL = databaseURL ?? Self.defaultDatabaseURL()

        if let store = try? SQLiteSnapshotStore(databaseURL: resolvedDatabaseURL, fileManager: fileManager) {
            self.snapshotStore = store
            if let loaded = try? store.loadMeetings() {
                let migrated = Self.normalizeLegacyPlannerTypos(in: loaded)
                self.meetings = Dictionary(uniqueKeysWithValues: migrated.map { ($0.id, $0) })
                if migrated != loaded {
                    try? store.saveMeetings(migrated, updatedAt: now())
                }
            } else {
                self.meetings = [:]
            }
        } else {
            self.snapshotStore = nil
            self.meetings = [:]
        }
    }

    public nonisolated static func defaultDatabaseURL(
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".quorum", isDirectory: true)
            .appendingPathComponent("quorum.db", isDirectory: false)
    }

    @discardableResult
    public func createMeeting(
        title: String,
        goal: String = "",
        defaultSkill: MeetingSkillDocument? = nil,
        additionalSkills: [MeetingSkillDocument] = []
    ) -> Meeting {
        let meeting = Meeting(
            title: title,
            goal: goal,
            createdAt: now(),
            phase: .lobby,
            defaultSkill: defaultSkill,
            additionalSkills: additionalSkills
        )
        meetings[meeting.id] = meeting
        persistSnapshot()
        return meeting
    }

    public func listMeetings() -> [Meeting] {
        meetings.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    public func meeting(id: UUID) throws -> Meeting {
        guard let meeting = meetings[id] else {
            throw MeetingRuntimeError.meetingNotFound(id)
        }
        return meeting
    }

    @discardableResult
    public func deleteMeeting(id: UUID) throws -> Meeting {
        guard let deleted = meetings.removeValue(forKey: id) else {
            throw MeetingRuntimeError.meetingNotFound(id)
        }
        persistSnapshot()
        return deleted
    }

    @discardableResult
    public func addParticipant(meetingID: UUID, participant: Participant) throws -> Meeting {
        var meeting = try resolveMeeting(meetingID)
        let normalizedAlias = Self.correctedPlannerTypo(
            in: participant.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let lowered = normalizedAlias.lowercased()
        if meeting.participants.contains(where: { $0.alias.lowercased() == lowered }) {
            throw MeetingRuntimeError.aliasAlreadyExists(normalizedAlias)
        }

        var normalizedParticipant = participant
        normalizedParticipant.alias = normalizedAlias
        normalizedParticipant.displayName = Self.correctedPlannerTypo(in: participant.displayName)
        if let initialSkill = normalizedParticipant.initialSkill {
            normalizedParticipant.initialSkill = Self.normalizeLegacyPlannerTypos(in: initialSkill)
        }
        meeting.participants.append(normalizedParticipant)
        meetings[meeting.id] = meeting
        persistSnapshot()
        return meeting
    }

    @discardableResult
    public func startMeeting(id: UUID) throws -> Meeting {
        var meeting = try resolveMeeting(id)
        if meeting.phase == .ended {
            throw MeetingRuntimeError.meetingAlreadyEnded(id)
        }
        let count = meeting.participants.count
        guard participantLimit.contains(count) else {
            throw MeetingRuntimeError.participantCountOutOfRange(actual: count, allowed: participantLimit)
        }

        meeting.phase = .running
        if meeting.startedAt == nil {
            meeting.startedAt = now()
        }
        meeting.endedAt = nil
        meeting.terminationReason = nil
        meetings[id] = meeting
        persistSnapshot()
        return meeting
    }

    @discardableResult
    public func postMessage(
        meetingID: UUID,
        fromAlias: String,
        toAliases: [String],
        content: String,
        activeRole: ParticipantRole? = nil
    ) throws -> MeetingMessage {
        var meeting = try resolveMeeting(meetingID)
        guard meeting.phase == .running else {
            throw MeetingRuntimeError.meetingNotRunning(meetingID)
        }

        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            throw MeetingRuntimeError.emptyMessage
        }

        let normalizedFrom = Self.correctedPlannerTypo(
            in: fromAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let normalizedTargets = toAliases.map(Self.correctedPlannerTypo)
        guard let sender = meeting.participants.first(where: {
            $0.alias.caseInsensitiveCompare(normalizedFrom) == .orderedSame
        }) else {
            throw MeetingRuntimeError.participantNotFound(normalizedFrom)
        }

        let message = MeetingMessage(
            fromAlias: normalizedFrom,
            toAliases: normalizedTargets,
            activeRole: activeRole,
            content: trimmedContent,
            createdAt: now()
        )
        meeting.messages.append(message)
        if sender.roles.contains(.host),
           let patch = Self.parseHostTopicContractPatch(from: trimmedContent)
        {
            meeting.topicContract = Self.updatedTopicContract(
                from: meeting.topicContract,
                patch: patch,
                updatedByAlias: normalizedFrom,
                now: now()
            )
        }
        meetings[meetingID] = meeting
        persistSnapshot()
        return message
    }

    @discardableResult
    public func deleteMessage(meetingID: UUID, messageID: UUID) throws -> MeetingMessage {
        var meeting = try resolveMeeting(meetingID)
        guard let index = meeting.messages.firstIndex(where: { $0.id == messageID }) else {
            throw MeetingRuntimeError.messageNotFound(messageID)
        }

        let deleted = meeting.messages.remove(at: index)
        meetings[meetingID] = meeting
        persistSnapshot()
        return deleted
    }

    @discardableResult
    public func recordExecutionLog(meetingID: UUID, log: AgentExecutionLog) throws -> Meeting {
        var meeting = try resolveMeeting(meetingID)
        meeting.executionLogs.append(Self.normalizeLegacyPlannerTypos(in: log))
        meetings[meetingID] = meeting
        persistSnapshot()
        return meeting
    }

    @discardableResult
    public func attachPath(meetingID: UUID, path: String) throws -> MeetingAttachment {
        var meeting = try resolveMeeting(meetingID)
        guard meeting.phase == .running else {
            throw MeetingRuntimeError.meetingNotRunning(meetingID)
        }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPath.hasPrefix("/") else {
            throw MeetingRuntimeError.pathMustBeAbsolute(path)
        }

        guard fileManager.fileExists(atPath: normalizedPath) else {
            throw MeetingRuntimeError.pathNotFound(normalizedPath)
        }

        let kind = Self.detectAttachmentKind(path: normalizedPath)
        let attachment = MeetingAttachment(path: normalizedPath, kind: kind, createdAt: now())
        meeting.attachments.append(attachment)
        meetings[meetingID] = meeting
        persistSnapshot()
        return attachment
    }

    @discardableResult
    public func stopMeeting(id: UUID, reason: MeetingTerminationReason = .manualStop) throws -> Meeting {
        var meeting = try resolveMeeting(id)
        meeting.phase = .ended
        meeting.endedAt = now()
        meeting.terminationReason = reason
        if reason == .judgeTerminated {
            meeting.judgeDecision = .terminate
        }
        meetings[id] = meeting
        persistSnapshot()
        return meeting
    }

    @discardableResult
    public func updatePolicy(meetingID: UUID, policy: MeetingPolicy) throws -> Meeting {
        var meeting = try resolveMeeting(meetingID)
        meeting.policy = MeetingPolicy(
            mode: policy.mode,
            maxConcurrentAgents: policy.maxConcurrentAgents,
            judgeAutoDecision: policy.judgeAutoDecision
        )
        meetings[meetingID] = meeting
        persistSnapshot()
        return meeting
    }

    @discardableResult
    public func updateTopicContract(
        meetingID: UUID,
        updatedByAlias: String,
        objective: String? = nil,
        deliverable: String? = nil,
        constraints: [String]? = nil
    ) throws -> MeetingTopicContract {
        var meeting = try resolveMeeting(meetingID)
        let normalizedAlias = Self.correctedPlannerTypo(
            in: updatedByAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let participant = meeting.participants.first(where: {
            $0.alias.caseInsensitiveCompare(normalizedAlias) == .orderedSame
        }) else {
            throw MeetingRuntimeError.participantNotFound(normalizedAlias)
        }
        guard participant.roles.contains(.host) else {
            throw MeetingRuntimeError.participantNotHost(normalizedAlias)
        }

        let patch = TopicContractPatch(
            objective: objective,
            deliverable: deliverable,
            constraints: constraints
        )
        guard patch.hasAnyField else {
            return meeting.topicContract
        }

        meeting.topicContract = Self.updatedTopicContract(
            from: meeting.topicContract,
            patch: patch,
            updatedByAlias: participant.alias,
            now: now()
        )
        meetings[meetingID] = meeting
        persistSnapshot()
        return meeting.topicContract
    }

    @discardableResult
    public func upsertParticipantMemory(
        meetingID: UUID,
        memory: ParticipantMemory
    ) throws -> Meeting {
        var meeting = try resolveMeeting(meetingID)
        var normalized = Self.normalizeLegacyPlannerTypos(in: memory)
        let normalizedAlias = normalized.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let participant = meeting.participants.first(where: {
            $0.alias.caseInsensitiveCompare(normalizedAlias) == .orderedSame
        }) else {
            throw MeetingRuntimeError.participantNotFound(normalizedAlias)
        }

        normalized.alias = participant.alias
        normalized.role = participant.primaryRole
        if let index = meeting.participantMemories.firstIndex(where: {
            $0.alias.caseInsensitiveCompare(participant.alias) == .orderedSame
        }) {
            meeting.participantMemories[index] = normalized
        } else {
            meeting.participantMemories.append(normalized)
        }

        meetings[meetingID] = meeting
        persistSnapshot()
        return meeting
    }

    @discardableResult
    public func recordJudgeDecision(meetingID: UUID, decision: MeetingJudgeDecision) throws -> Meeting {
        var meeting = try resolveMeeting(meetingID)
        meeting.judgeDecision = decision
        meetings[meetingID] = meeting
        persistSnapshot()
        return meeting
    }

    @discardableResult
    public func shutdown(reason: MeetingTerminationReason) -> [Meeting] {
        let runningIDs = meetings.values.filter { $0.phase == .running }.map(\.id)
        for id in runningIDs {
            if var meeting = meetings[id] {
                meeting.phase = .ended
                meeting.endedAt = now()
                meeting.terminationReason = reason
                meetings[id] = meeting
            }
        }
        persistSnapshot()
        return listMeetings()
    }

    public func exportMeetingMarkdown(id: UUID) throws -> String {
        let meeting = try resolveMeeting(id)
        var lines: [String] = []
        lines.append("# \(meeting.title)")
        if !meeting.goal.isEmpty {
            lines.append("")
            lines.append("Goal: \(meeting.goal)")
        }
        lines.append("Objective: \(meeting.topicContract.objective)")
        if !meeting.topicContract.deliverable.isEmpty {
            lines.append("Deliverable: \(meeting.topicContract.deliverable)")
        }
        if !meeting.topicContract.constraints.isEmpty {
            lines.append("Constraints: \(meeting.topicContract.constraints.joined(separator: " | "))")
        }
        lines.append("")
        lines.append("Phase: \(meeting.phase.rawValue)")
        lines.append("Participants: \(meeting.participants.count)")
        lines.append("")
        lines.append("## Participants")
        for participant in meeting.participants {
            let roles = participant.roles.map(\.rawValue).joined(separator: ",")
            lines.append("- \(participant.displayName) (@\(participant.alias)) [\(participant.provider)/\(participant.model)] roles=\(roles)")
        }

        lines.append("")
        lines.append("## Skills")
        if let defaultSkill = meeting.defaultSkill {
            lines.append("- default: \(defaultSkill.name)")
        } else {
            lines.append("- default: (none)")
        }
        if meeting.additionalSkills.isEmpty {
            lines.append("- additional: (none)")
        } else {
            for skill in meeting.additionalSkills {
                lines.append("- additional: \(skill.name)")
            }
        }

        lines.append("")
        lines.append("## Messages")
        if meeting.messages.isEmpty {
            lines.append("- (none)")
        } else {
            for message in meeting.messages {
                let target = message.toAliases.joined(separator: ",")
                lines.append("- [\(message.createdAt.ISO8601Format())] @\(message.fromAlias) -> [\(target)]: \(message.content)")
            }
        }

        lines.append("")
        lines.append("## Attachments")
        if meeting.attachments.isEmpty {
            lines.append("- (none)")
        } else {
            for attachment in meeting.attachments {
                lines.append("- [\(attachment.kind.rawValue)] \(attachment.path)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private func persistSnapshot() {
        guard let snapshotStore else { return }
        do {
            try snapshotStore.saveMeetings(listMeetings(), updatedAt: now())
        } catch {
            // Persistence failures should not crash the meeting loop.
            FileHandle.standardError.write(
                Data("quorum: failed to persist meetings to SQLite: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    private func resolveMeeting(_ id: UUID) throws -> Meeting {
        guard let meeting = meetings[id] else {
            throw MeetingRuntimeError.meetingNotFound(id)
        }
        return meeting
    }

    private static func normalizeLegacyPlannerTypos(in meetings: [Meeting]) -> [Meeting] {
        meetings.map(normalizeLegacyPlannerTypos)
    }

    private static func normalizeLegacyPlannerTypos(in meeting: Meeting) -> Meeting {
        var normalized = meeting
        normalized.participants = meeting.participants.map(normalizeLegacyPlannerTypos)
        normalized.messages = meeting.messages.map(normalizeLegacyPlannerTypos)
        normalized.executionLogs = meeting.executionLogs.map(normalizeLegacyPlannerTypos)
        normalized.topicContract = normalizeLegacyPlannerTypos(in: meeting.topicContract)
        normalized.participantMemories = meeting.participantMemories.map(normalizeLegacyPlannerTypos)
        if let defaultSkill = meeting.defaultSkill {
            normalized.defaultSkill = normalizeLegacyPlannerTypos(in: defaultSkill)
        }
        normalized.additionalSkills = meeting.additionalSkills.map(normalizeLegacyPlannerTypos)
        return normalized
    }

    private static func normalizeLegacyPlannerTypos(in participant: Participant) -> Participant {
        var normalized = participant
        normalized.alias = correctedPlannerTypo(in: participant.alias)
        normalized.displayName = correctedPlannerTypo(in: participant.displayName)
        if let initialSkill = participant.initialSkill {
            normalized.initialSkill = normalizeLegacyPlannerTypos(in: initialSkill)
        }
        return normalized
    }

    private static func normalizeLegacyPlannerTypos(in message: MeetingMessage) -> MeetingMessage {
        var normalized = message
        normalized.fromAlias = correctedPlannerTypo(in: message.fromAlias)
        normalized.toAliases = message.toAliases.map(correctedPlannerTypo)
        normalized.content = correctedPlannerTypo(in: message.content)
        return normalized
    }

    private static func normalizeLegacyPlannerTypos(in log: AgentExecutionLog) -> AgentExecutionLog {
        var normalized = log
        normalized.participantAlias = correctedPlannerTypo(in: log.participantAlias)
        normalized.participantDisplayName = correctedPlannerTypo(in: log.participantDisplayName)
        normalized.prompt = correctedPlannerTypo(in: log.prompt)
        normalized.response = correctedPlannerTypo(in: log.response)
        normalized.diagnostics = log.diagnostics.map(correctedPlannerTypo)
        return normalized
    }

    private static func normalizeLegacyPlannerTypos(in skill: MeetingSkillDocument) -> MeetingSkillDocument {
        var normalized = skill
        normalized.name = correctedPlannerTypo(in: skill.name)
        normalized.content = correctedPlannerTypo(in: skill.content)
        if let filePath = skill.filePath {
            normalized.filePath = correctedPlannerTypo(in: filePath)
        }
        return normalized
    }

    private static func normalizeLegacyPlannerTypos(in topic: MeetingTopicContract) -> MeetingTopicContract {
        var normalized = topic
        normalized.objective = correctedPlannerTypo(in: topic.objective)
        normalized.deliverable = correctedPlannerTypo(in: topic.deliverable)
        normalized.constraints = topic.constraints.map(correctedPlannerTypo)
        normalized.updatedByAlias = correctedPlannerTypo(in: topic.updatedByAlias)
        return normalized
    }

    private static func normalizeLegacyPlannerTypos(in memory: ParticipantMemory) -> ParticipantMemory {
        var normalized = memory
        normalized.alias = correctedPlannerTypo(in: memory.alias)
        normalized.summary = correctedPlannerTypo(in: memory.summary)
        normalized.lastStatus = correctedPlannerTypo(in: memory.lastStatus)
        if let reason = memory.lastReason {
            normalized.lastReason = correctedPlannerTypo(in: reason)
        }
        if let artifact = memory.lastArtifactPath {
            normalized.lastArtifactPath = correctedPlannerTypo(in: artifact)
        }
        return normalized
    }

    private static func updatedTopicContract(
        from current: MeetingTopicContract,
        patch: TopicContractPatch,
        updatedByAlias: String,
        now: Date
    ) -> MeetingTopicContract {
        var next = current
        if let objective = patch.objective {
            next.objective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let deliverable = patch.deliverable {
            next.deliverable = deliverable.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let constraints = patch.constraints {
            next.constraints = constraints.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }
        next.version += 1
        next.updatedAt = now
        next.updatedByAlias = updatedByAlias
        return next
    }

    private static func parseHostTopicContractPatch(from content: String) -> TopicContractPatch? {
        var objective: String?
        var deliverable: String?
        var constraints: [String]?

        let lines = content.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for line in lines where !line.isEmpty {
            let lowered = line.lowercased()
            if lowered.hasPrefix("objective:") {
                let value = line.dropFirst("objective:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                objective = value
                continue
            }
            if line.hasPrefix("目标:") || line.hasPrefix("目标：") {
                objective = extractColonValue(line)
                continue
            }

            if lowered.hasPrefix("deliverable:") {
                let value = line.dropFirst("deliverable:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                deliverable = value
                continue
            }
            if line.hasPrefix("产物:") || line.hasPrefix("产物：") {
                deliverable = extractColonValue(line)
                continue
            }

            if lowered.hasPrefix("constraints:") {
                let value = line.dropFirst("constraints:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                constraints = splitConstraints(value)
                continue
            }
            if line.hasPrefix("约束:") || line.hasPrefix("约束：") {
                if let value = extractColonValue(line) {
                    constraints = splitConstraints(value)
                }
                continue
            }
        }

        let patch = TopicContractPatch(
            objective: objective,
            deliverable: deliverable,
            constraints: constraints
        )
        return patch.hasAnyField ? patch : nil
    }

    private static func splitConstraints(_ raw: String) -> [String] {
        let delimiters: Set<Character> = [",", "，", ";", "；", "|"]
        return raw
            .split(whereSeparator: { delimiters.contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func extractColonValue(_ line: String) -> String? {
        if let range = line.range(of: "：") ?? line.range(of: ":") {
            let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func correctedPlannerTypo(in text: String) -> String {
        guard text.range(of: "planer", options: .caseInsensitive) != nil else {
            return text
        }

        let pattern = #"\bplaner\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.replacingOccurrences(of: "planer", with: "planner")
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return text
        }

        var normalized = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: normalized) else { continue }
            let original = String(normalized[range])
            let replacement: String
            if original == original.uppercased() {
                replacement = "PLANNER"
            } else if let first = original.first, String(first) == String(first).uppercased() {
                replacement = "Planner"
            } else {
                replacement = "planner"
            }
            normalized.replaceSubrange(range, with: replacement)
        }
        return normalized
    }

    private static func detectAttachmentKind(path: String) -> MeetingAttachmentKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif"
        ]
        return imageExtensions.contains(ext) ? .image : .file
    }
}
