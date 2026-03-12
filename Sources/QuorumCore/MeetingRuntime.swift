import Foundation

public actor MeetingRuntime {
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
                self.meetings = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
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
        let normalizedAlias = participant.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalizedAlias.lowercased()
        if meeting.participants.contains(where: { $0.alias.lowercased() == lowered }) {
            throw MeetingRuntimeError.aliasAlreadyExists(normalizedAlias)
        }

        var normalizedParticipant = participant
        normalizedParticipant.alias = normalizedAlias
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

        let normalizedFrom = fromAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard meeting.participants.contains(where: { $0.alias.caseInsensitiveCompare(normalizedFrom) == .orderedSame }) else {
            throw MeetingRuntimeError.participantNotFound(normalizedFrom)
        }

        let message = MeetingMessage(
            fromAlias: normalizedFrom,
            toAliases: toAliases,
            activeRole: activeRole,
            content: trimmedContent,
            createdAt: now()
        )
        meeting.messages.append(message)
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
        meeting.executionLogs.append(log)
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

    private static func detectAttachmentKind(path: String) -> MeetingAttachmentKind {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "heic", "heif"
        ]
        return imageExtensions.contains(ext) ? .image : .file
    }
}
