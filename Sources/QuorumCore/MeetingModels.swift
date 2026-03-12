import Foundation

public enum ParticipantRole: String, Codable, CaseIterable, Sendable {
    case host
    case planner
    case reviewer
    case judge
    case observer
}

public enum MeetingPhase: String, Codable, CaseIterable, Sendable {
    case lobby
    case running
    case ended
}

public enum MeetingJudgeDecision: String, Codable, CaseIterable, Sendable {
    case `continue`
    case converge
    case terminate
}

public enum MeetingTerminationReason: String, Codable, CaseIterable, Sendable {
    case manualStop
    case judgeTerminated
    case appShutdown
    case cliStopped
}

public enum MeetingAttachmentKind: String, Codable, CaseIterable, Sendable {
    case file
    case image
}

public enum MeetingSpeakingMode: String, Codable, CaseIterable, Sendable {
    case roundRobin
    case judgeGated
    case free
}

public struct MeetingPolicy: Codable, Hashable, Sendable {
    public var mode: MeetingSpeakingMode
    public var maxConcurrentAgents: Int
    public var judgeAutoDecision: Bool

    public init(
        mode: MeetingSpeakingMode = .roundRobin,
        maxConcurrentAgents: Int = 1,
        judgeAutoDecision: Bool = true
    ) {
        self.mode = mode
        self.maxConcurrentAgents = max(1, maxConcurrentAgents)
        self.judgeAutoDecision = judgeAutoDecision
    }

    public static let `default` = MeetingPolicy()
}

public struct Participant: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var alias: String
    public var displayName: String
    public var provider: String
    public var model: String
    public var roles: [ParticipantRole]

    public init(
        id: UUID = UUID(),
        alias: String,
        displayName: String,
        provider: String,
        model: String,
        roles: [ParticipantRole]
    ) {
        self.id = id
        self.alias = alias
        self.displayName = displayName
        self.provider = provider
        self.model = model
        self.roles = Participant.normalizedRoles(from: roles)
    }

    public var primaryRole: ParticipantRole {
        roles.first ?? .observer
    }

    private static func normalizedRoles(from roles: [ParticipantRole]) -> [ParticipantRole] {
        var deduped: [ParticipantRole] = []
        for role in roles where !deduped.contains(role) {
            deduped.append(role)
        }
        if deduped.isEmpty {
            return [.observer]
        }
        return deduped
    }
}

public struct MeetingMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var fromAlias: String
    public var toAliases: [String]
    public var activeRole: ParticipantRole?
    public var content: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        fromAlias: String,
        toAliases: [String],
        activeRole: ParticipantRole? = nil,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fromAlias = fromAlias
        self.toAliases = toAliases
        self.activeRole = activeRole
        self.content = content
        self.createdAt = createdAt
    }
}

public struct MeetingAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var kind: MeetingAttachmentKind
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        path: String,
        kind: MeetingAttachmentKind,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.createdAt = createdAt
    }
}

public struct Meeting: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var goal: String
    public var createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var phase: MeetingPhase
    public var participants: [Participant]
    public var messages: [MeetingMessage]
    public var attachments: [MeetingAttachment]
    public var policy: MeetingPolicy
    public var judgeDecision: MeetingJudgeDecision?
    public var terminationReason: MeetingTerminationReason?

    public init(
        id: UUID = UUID(),
        title: String,
        goal: String = "",
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        phase: MeetingPhase = .lobby,
        participants: [Participant] = [],
        messages: [MeetingMessage] = [],
        attachments: [MeetingAttachment] = [],
        policy: MeetingPolicy = .default,
        judgeDecision: MeetingJudgeDecision? = nil,
        terminationReason: MeetingTerminationReason? = nil
    ) {
        self.id = id
        self.title = title
        self.goal = goal
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.phase = phase
        self.participants = participants
        self.messages = messages
        self.attachments = attachments
        self.policy = policy
        self.judgeDecision = judgeDecision
        self.terminationReason = terminationReason
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case goal
        case createdAt
        case startedAt
        case endedAt
        case phase
        case participants
        case messages
        case attachments
        case policy
        case judgeDecision
        case terminationReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        phase = try container.decode(MeetingPhase.self, forKey: .phase)
        participants = try container.decodeIfPresent([Participant].self, forKey: .participants) ?? []
        messages = try container.decodeIfPresent([MeetingMessage].self, forKey: .messages) ?? []
        attachments = try container.decodeIfPresent([MeetingAttachment].self, forKey: .attachments) ?? []
        policy = try container.decodeIfPresent(MeetingPolicy.self, forKey: .policy) ?? .default
        judgeDecision = try container.decodeIfPresent(MeetingJudgeDecision.self, forKey: .judgeDecision)
        terminationReason = try container.decodeIfPresent(MeetingTerminationReason.self, forKey: .terminationReason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(goal, forKey: .goal)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(phase, forKey: .phase)
        try container.encode(participants, forKey: .participants)
        try container.encode(messages, forKey: .messages)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(policy, forKey: .policy)
        try container.encodeIfPresent(judgeDecision, forKey: .judgeDecision)
        try container.encodeIfPresent(terminationReason, forKey: .terminationReason)
    }
}

public enum MeetingRuntimeError: Error, Equatable, Sendable {
    case meetingNotFound(UUID)
    case aliasAlreadyExists(String)
    case participantCountOutOfRange(actual: Int, allowed: ClosedRange<Int>)
    case meetingNotRunning(UUID)
    case meetingAlreadyEnded(UUID)
    case participantNotFound(String)
    case emptyMessage
    case pathMustBeAbsolute(String)
    case pathNotFound(String)
}

extension MeetingRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .meetingNotFound(let id):
            return "Meeting not found: \(id.uuidString.lowercased())"
        case .aliasAlreadyExists(let alias):
            return "Alias already exists in meeting: \(alias)"
        case .participantCountOutOfRange(let actual, let allowed):
            return "Participant count out of range. actual=\(actual), allowed=\(allowed.lowerBound)...\(allowed.upperBound)"
        case .meetingNotRunning(let id):
            return "Meeting is not running: \(id.uuidString.lowercased())"
        case .meetingAlreadyEnded(let id):
            return "Meeting is already ended: \(id.uuidString.lowercased())"
        case .participantNotFound(let alias):
            return "Participant not found for alias: \(alias)"
        case .emptyMessage:
            return "Message content cannot be empty"
        case .pathMustBeAbsolute(let path):
            return "Attachment path must be absolute: \(path)"
        case .pathNotFound(let path):
            return "Attachment path not found: \(path)"
        }
    }
}
