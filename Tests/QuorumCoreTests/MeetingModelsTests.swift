import Foundation
import Testing
@testable import QuorumCore

@Test("Host can also be judge and alias must be unique")
func participantRules() async throws {
    let runtime = makeRuntime()
    let meeting = await runtime.createMeeting(title: "Design Review", goal: "Pick one plan")

    let hostJudge = Participant(
        alias: "me",
        displayName: "You",
        provider: "human",
        model: "human",
        roles: [.host, .judge]
    )
    _ = try await runtime.addParticipant(meetingID: meeting.id, participant: hostJudge)

    let duplicate = Participant(
        alias: "me",
        displayName: "My Clone",
        provider: "human",
        model: "human",
        roles: [.observer]
    )

    do {
        _ = try await runtime.addParticipant(meetingID: meeting.id, participant: duplicate)
        Issue.record("Expected duplicate alias to fail")
    } catch let error as MeetingRuntimeError {
        #expect(error == .aliasAlreadyExists("me"))
    }
}

@Test("Meeting start requires 3 to 6 participants")
func meetingStartParticipantCountRule() async throws {
    let runtime = makeRuntime()
    let meeting = await runtime.createMeeting(title: "Architecture", goal: "Finalize API")

    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "me", displayName: "You", provider: "human", model: "human", roles: [.host, .judge])
    )
    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "claude-a", displayName: "Claude A", provider: "claude", model: "claude-sonnet", roles: [.planner])
    )

    do {
        _ = try await runtime.startMeeting(id: meeting.id)
        Issue.record("Expected start failure for participant count < 3")
    } catch let error as MeetingRuntimeError {
        #expect(error == .participantCountOutOfRange(actual: 2, allowed: 3 ... 6))
    }

    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "codex-r1", displayName: "Codex", provider: "codex", model: "gpt-5", roles: [.reviewer])
    )

    let started = try await runtime.startMeeting(id: meeting.id)
    #expect(started.phase == .running)
}

@Test("Messages are isolated by room and meetings keep running until explicit stop")
func multiRoomIsolationAndLifecycle() async throws {
    let runtime = makeRuntime()
    let roomA = await runtime.createMeeting(title: "Room A", goal: "A")
    let roomB = await runtime.createMeeting(title: "Room B", goal: "B")

    for (meetingID, seed) in [(roomA.id, "a"), (roomB.id, "b")] {
        _ = try await runtime.addParticipant(
            meetingID: meetingID,
            participant: Participant(alias: "\(seed)-host", displayName: "Host", provider: "human", model: "human", roles: [.host, .judge])
        )
        _ = try await runtime.addParticipant(
            meetingID: meetingID,
            participant: Participant(alias: "\(seed)-planner", displayName: "Planner", provider: "claude", model: "claude-sonnet", roles: [.planner])
        )
        _ = try await runtime.addParticipant(
            meetingID: meetingID,
            participant: Participant(alias: "\(seed)-reviewer", displayName: "Reviewer", provider: "codex", model: "gpt-5", roles: [.reviewer])
        )
        _ = try await runtime.startMeeting(id: meetingID)
    }

    _ = try await runtime.postMessage(
        meetingID: roomA.id,
        fromAlias: "a-host",
        toAliases: ["all"],
        content: "A only"
    )

    let aState = try await runtime.meeting(id: roomA.id)
    let bState = try await runtime.meeting(id: roomB.id)

    #expect(aState.messages.count == 1)
    #expect(bState.messages.isEmpty)
    #expect(aState.phase == .running)
    #expect(bState.phase == .running)

    _ = try await runtime.stopMeeting(id: roomA.id, reason: .manualStop)
    let stoppedA = try await runtime.meeting(id: roomA.id)
    let stillRunningB = try await runtime.meeting(id: roomB.id)
    #expect(stoppedA.phase == .ended)
    #expect(stillRunningB.phase == .running)
}

@Test("Attachment path must be absolute and exist")
func attachmentPathValidation() async throws {
    let runtime = makeRuntime()
    let meeting = await runtime.createMeeting(title: "Attach", goal: "Attach files")

    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "me", displayName: "You", provider: "human", model: "human", roles: [.host, .judge])
    )
    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "claude-a", displayName: "Claude", provider: "claude", model: "claude-sonnet", roles: [.planner])
    )
    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "codex-r1", displayName: "Codex", provider: "codex", model: "gpt-5", roles: [.reviewer])
    )
    _ = try await runtime.startMeeting(id: meeting.id)

    do {
        _ = try await runtime.attachPath(meetingID: meeting.id, path: "relative/path.md")
        Issue.record("Expected relative path to fail")
    } catch let error as MeetingRuntimeError {
        #expect(error == .pathMustBeAbsolute("relative/path.md"))
    }

    do {
        _ = try await runtime.attachPath(meetingID: meeting.id, path: "/tmp/quorum-not-exists-file-123456.md")
        Issue.record("Expected missing path to fail")
    } catch let error as MeetingRuntimeError {
        #expect(error == .pathNotFound("/tmp/quorum-not-exists-file-123456.md"))
    }

    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("quorum-attach-\(UUID().uuidString).png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let attachment = try await runtime.attachPath(meetingID: meeting.id, path: tempURL.path)
    #expect(attachment.kind == .image)
    #expect(attachment.path == tempURL.path)
}

@Test("CLI/app shutdown ends running rooms")
func shutdownEndsRunningMeetings() async throws {
    let runtime = makeRuntime()
    let meeting = await runtime.createMeeting(title: "Shutdown", goal: "test")

    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "me", displayName: "You", provider: "human", model: "human", roles: [.host, .judge])
    )
    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "claude-a", displayName: "Claude", provider: "claude", model: "claude-sonnet", roles: [.planner])
    )
    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "codex-r1", displayName: "Codex", provider: "codex", model: "gpt-5", roles: [.reviewer])
    )
    _ = try await runtime.startMeeting(id: meeting.id)

    _ = await runtime.shutdown(reason: .cliStopped)
    let ended = try await runtime.meeting(id: meeting.id)
    #expect(ended.phase == .ended)
    #expect(ended.terminationReason == .cliStopped)
}

@Test("Meeting policy is persisted in SQLite snapshot")
func policyPersistence() async throws {
    let databaseURL = temporaryDatabaseURL()
    let runtimeA = MeetingRuntime(databaseURL: databaseURL)
    let created = await runtimeA.createMeeting(title: "Policy", goal: "Persist policy")
    _ = try await runtimeA.updatePolicy(
        meetingID: created.id,
        policy: MeetingPolicy(mode: .judgeGated, maxConcurrentAgents: 1, judgeAutoDecision: false)
    )

    let runtimeB = MeetingRuntime(databaseURL: databaseURL)
    let loaded = try await runtimeB.meeting(id: created.id)
    #expect(loaded.policy.mode == .judgeGated)
    #expect(loaded.policy.maxConcurrentAgents == 1)
    #expect(loaded.policy.judgeAutoDecision == false)
}

@Test("Meeting uses default policy and clamps invalid max concurrent value")
func defaultPolicyAndClamp() async throws {
    let runtime = makeRuntime()
    let created = await runtime.createMeeting(title: "Defaults", goal: "policy defaults")
    #expect(created.policy.mode == .roundRobin)
    #expect(created.policy.maxConcurrentAgents == 1)
    #expect(created.policy.judgeAutoDecision == true)

    let updated = try await runtime.updatePolicy(
        meetingID: created.id,
        policy: MeetingPolicy(mode: .free, maxConcurrentAgents: 0, judgeAutoDecision: true)
    )
    #expect(updated.policy.mode == .free)
    #expect(updated.policy.maxConcurrentAgents == 1)
}

@Test("Message deletion removes item and reports missing message")
func messageDeletion() async throws {
    let runtime = makeRuntime()
    let meeting = await runtime.createMeeting(title: "Delete Message", goal: "cleanup")

    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "me", displayName: "You", provider: "human", model: "human", roles: [.host, .judge])
    )
    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "claude-a", displayName: "Claude", provider: "claude", model: "claude-sonnet", roles: [.planner])
    )
    _ = try await runtime.addParticipant(
        meetingID: meeting.id,
        participant: Participant(alias: "codex-r1", displayName: "Codex", provider: "codex", model: "gpt-5", roles: [.reviewer])
    )
    _ = try await runtime.startMeeting(id: meeting.id)

    let message = try await runtime.postMessage(
        meetingID: meeting.id,
        fromAlias: "me",
        toAliases: ["all"],
        content: "这条消息会被删除"
    )

    let deleted = try await runtime.deleteMessage(meetingID: meeting.id, messageID: message.id)
    #expect(deleted.id == message.id)

    let latest = try await runtime.meeting(id: meeting.id)
    #expect(latest.messages.isEmpty)

    do {
        _ = try await runtime.deleteMessage(meetingID: meeting.id, messageID: message.id)
        Issue.record("Expected deleting missing message to fail")
    } catch let error as MeetingRuntimeError {
        #expect(error == .messageNotFound(message.id))
    }
}

private func makeRuntime() -> MeetingRuntime {
    MeetingRuntime(databaseURL: temporaryDatabaseURL())
}

private func temporaryDatabaseURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("quorum-test-\(UUID().uuidString.lowercased()).db")
}
