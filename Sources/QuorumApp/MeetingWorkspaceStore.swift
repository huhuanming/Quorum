import Foundation
import Observation
import QuorumCore

@MainActor
@Observable
final class MeetingWorkspaceStore {
    private static let sharedRuntime = MeetingRuntime()
    private static let sharedOrchestrator = MeetingOrchestrator(runtime: sharedRuntime)

    private let runtime: MeetingRuntime
    private let orchestrator: MeetingOrchestrator
    private let selfAlias = "me"
    private var messageCountByRoom: [UUID: Int] = [:]
    private var pollTask: Task<Void, Never>?
    private var statusClearTask: Task<Void, Never>?

    private(set) var meetings: [Meeting] = []
    private(set) var activeMeetingID: UUID?
    private(set) var unreadByRoom: [UUID: Int] = [:]
    private(set) var autopilotByRoom: [UUID: Bool] = [:]
    private(set) var isBootstrapping = true
    private(set) var isStartingMeeting = false
    private(set) var isRunningRound = false
    private(set) var isTogglingAutopilot = false
    private(set) var isStoppingMeeting = false

    var draftMessage: String = ""
    var draftAttachmentPath: String = ""
    var lastError: String?
    var lastActionStatus: String?

    init(
        runtime: MeetingRuntime = MeetingWorkspaceStore.sharedRuntime,
        orchestrator: MeetingOrchestrator = MeetingWorkspaceStore.sharedOrchestrator
    ) {
        self.runtime = runtime
        self.orchestrator = orchestrator
        Task {
            await initialize()
        }
    }

    var activeMeeting: Meeting? {
        guard let activeMeetingID else { return nil }
        return meetings.first(where: { $0.id == activeMeetingID })
    }

    func selectMeeting(_ id: UUID) {
        activeMeetingID = id
        unreadByRoom[id] = 0
    }

    @discardableResult
    func createMeeting(
        title: String,
        goal: String,
        participants: [Participant],
        policy: MeetingPolicy,
        autoStart: Bool
    ) async throws -> UUID {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw NSError(
                domain: "QuorumApp",
                code: 101,
                userInfo: [NSLocalizedDescriptionKey: "Meeting title cannot be empty"]
            )
        }

        let created = await runtime.createMeeting(title: normalizedTitle, goal: goal)
        do {
            for participant in participants {
                _ = try await runtime.addParticipant(meetingID: created.id, participant: participant)
            }
            _ = try await runtime.updatePolicy(meetingID: created.id, policy: policy)
            if autoStart {
                _ = try await runtime.startMeeting(id: created.id)
            }
            await refreshSnapshot()
            selectMeeting(created.id)
            return created.id
        } catch {
            // Best effort cleanup when setup fails mid-way.
            _ = try? await runtime.stopMeeting(id: created.id, reason: .manualStop)
            await refreshSnapshot()
            throw error
        }
    }

    func startActiveMeetingIfNeeded() {
        guard let meeting = activeMeeting else { return }
        guard meeting.phase == .lobby else { return }
        isStartingMeeting = true
        Task {
            defer { isStartingMeeting = false }
            do {
                _ = try await runtime.startMeeting(id: meeting.id)
                await refreshSnapshot()
                setActionStatus("会议已开始")
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    func stopActiveMeeting() {
        guard let meeting = activeMeeting else { return }
        isStoppingMeeting = true
        Task {
            defer { isStoppingMeeting = false }
            do {
                try await orchestrator.setAutopilot(meetingID: meeting.id, enabled: false)
                _ = try await runtime.stopMeeting(id: meeting.id, reason: .manualStop)
                await refreshSnapshot()
                setActionStatus("会议已结束")
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    func runOneAgentRound() {
        guard let meeting = activeMeeting else { return }
        isRunningRound = true
        Task {
            defer { isRunningRound = false }
            do {
                _ = try await orchestrator.tick(meetingID: meeting.id)
                await refreshSnapshot()
                setActionStatus("已执行一轮")
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    func toggleAutopilot() {
        guard let meeting = activeMeeting else { return }
        let currentlyOn = autopilotByRoom[meeting.id, default: false]
        isTogglingAutopilot = true
        Task {
            defer { isTogglingAutopilot = false }
            do {
                try await orchestrator.setAutopilot(
                    meetingID: meeting.id,
                    enabled: !currentlyOn,
                    intervalMilliseconds: 1200
                )
                await refreshSnapshot()
                setActionStatus(!currentlyOn ? "自动轮询已开启" : "自动轮询已关闭")
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    @discardableResult
    func updateMeetingPolicy(meetingID: UUID, policy: MeetingPolicy) async throws -> Meeting {
        let updated = try await runtime.updatePolicy(meetingID: meetingID, policy: policy)
        await refreshSnapshot()
        return updated
    }

    func sendDraftMessage() {
        guard let meeting = activeMeeting else { return }
        let content = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        draftMessage = ""
        Task {
            do {
                _ = try await runtime.postMessage(
                    meetingID: meeting.id,
                    fromAlias: selfAlias,
                    toAliases: ["all"],
                    content: content
                )
                await refreshSnapshot()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    func attachDraftPath() {
        guard let meeting = activeMeeting else { return }
        let path = draftAttachmentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }

        draftAttachmentPath = ""
        Task {
            do {
                _ = try await runtime.attachPath(meetingID: meeting.id, path: path)
                await refreshSnapshot()
            } catch {
                setError(error.localizedDescription)
            }
        }
    }

    func participant(for alias: String, in meeting: Meeting) -> Participant? {
        meeting.participants.first {
            $0.alias.caseInsensitiveCompare(alias) == .orderedSame
        }
    }

    func badgeText(for participant: Participant) -> String {
        participant.roles.map(\.rawValue).joined(separator: " • ")
    }

    private func initialize() async {
        await refreshSnapshot()
        isBootstrapping = false
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshSnapshot()
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
    }

    private func refreshSnapshot() async {
        let latest = await runtime.listMeetings()
        var latestAutopilot: [UUID: Bool] = [:]

        for meeting in latest {
            let previous = messageCountByRoom[meeting.id] ?? 0
            let delta = max(0, meeting.messages.count - previous)
            if delta > 0, meeting.id != activeMeetingID {
                unreadByRoom[meeting.id, default: 0] += delta
            }
            messageCountByRoom[meeting.id] = meeting.messages.count
            latestAutopilot[meeting.id] = await orchestrator.autopilotEnabled(meetingID: meeting.id)
        }

        meetings = latest
        autopilotByRoom = latestAutopilot

        if let activeMeetingID {
            unreadByRoom[activeMeetingID] = 0
        } else if let first = latest.first {
            activeMeetingID = first.id
        }
    }

    private func setError(_ message: String) {
        statusClearTask?.cancel()
        lastActionStatus = nil
        lastError = message
    }

    func clearError() {
        lastError = nil
    }

    private func setActionStatus(_ message: String) {
        lastError = nil
        lastActionStatus = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let self else { return }
            self.lastActionStatus = nil
        }
    }
}
