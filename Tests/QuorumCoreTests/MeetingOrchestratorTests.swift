import Foundation
import Testing
@testable import QuorumCore

struct MeetingOrchestratorTests {
    @Test("Tick uses round-robin agents and sees user interjection in shared context")
    func roundRobinWithInterjection() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "Design", goal: "Finalize one plan")

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "me",
                displayName: "You",
                provider: "human",
                model: "human",
                roles: [.host, .judge]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "claude-a",
                displayName: "Claude A",
                provider: "claude",
                model: "claude-sonnet",
                roles: [.planner]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "codex-r1",
                displayName: "Codex R1",
                provider: "codex",
                model: "gpt-5",
                roles: [.reviewer]
            )
        )
        _ = try await runtime.startMeeting(id: meeting.id)

        _ = try await runtime.postMessage(
            meetingID: meeting.id,
            fromAlias: "me",
            toAliases: ["all"],
            content: "先给一个方案草案"
        )

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { context in
                    let last = context.lastMessages.last?.content ?? "(none)"
                    return "\(participant.alias) reply: \(last)"
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        let firstAgentMessage = try await orchestrator.tick(meetingID: meeting.id)
        #expect(firstAgentMessage.fromAlias == "claude-a")

        _ = try await runtime.postMessage(
            meetingID: meeting.id,
            fromAlias: "me",
            toAliases: ["all"],
            content: "请补充 code review 风险"
        )

        let secondAgentMessage = try await orchestrator.tick(meetingID: meeting.id)
        #expect(secondAgentMessage.fromAlias == "codex-r1")
        #expect(secondAgentMessage.content.contains("请补充 code review 风险"))

        let latest = try await runtime.meeting(id: meeting.id)
        let fromAliases = latest.messages.map(\.fromAlias)
        #expect(fromAliases == ["me", "claude-a", "me", "codex-r1"])
    }

    @Test("Judge agent decision terminate ends the meeting")
    func judgeTerminate() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "Terminate", goal: "Judge can stop")

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "me",
                displayName: "You",
                provider: "human",
                model: "human",
                roles: [.host]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "judge-ai",
                displayName: "Judge",
                provider: "codex",
                model: "gpt-5",
                roles: [.judge]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "planner-ai",
                displayName: "Planner",
                provider: "claude",
                model: "claude-sonnet",
                roles: [.planner]
            )
        )
        _ = try await runtime.startMeeting(id: meeting.id)

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    if participant.alias == "judge-ai" {
                        return "decision: terminate\n收敛完成，终止会议。"
                    }
                    return "继续推进。"
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        _ = try await orchestrator.tick(meetingID: meeting.id)
        let ended = try await runtime.meeting(id: meeting.id)
        #expect(ended.phase == .ended)
        #expect(ended.terminationReason == .judgeTerminated)
        #expect(ended.judgeDecision == .terminate)
    }

    @Test("Judge decision marker is ignored when policy disables auto decision")
    func judgeDecisionIgnoredWhenDisabled() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "No Auto Judge", goal: "manual only")

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "me",
                displayName: "You",
                provider: "human",
                model: "human",
                roles: [.host]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "judge-ai",
                displayName: "Judge",
                provider: "codex",
                model: "gpt-5",
                roles: [.judge]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "planner-ai",
                displayName: "Planner",
                provider: "claude",
                model: "claude-sonnet",
                roles: [.planner]
            )
        )
        _ = try await runtime.updatePolicy(
            meetingID: meeting.id,
            policy: MeetingPolicy(mode: .roundRobin, maxConcurrentAgents: 1, judgeAutoDecision: false)
        )
        _ = try await runtime.startMeeting(id: meeting.id)

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    if participant.alias == "judge-ai" {
                        return "decision: terminate\nI think we can stop."
                    }
                    return "planner says continue"
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        _ = try await orchestrator.tick(meetingID: meeting.id)
        _ = try await orchestrator.tick(meetingID: meeting.id)

        let latest = try await runtime.meeting(id: meeting.id)
        #expect(latest.phase == .running)
        #expect(latest.judgeDecision == nil)
    }

    @Test("Autopilot is isolated per meeting and can be stopped independently")
    func autopilotIsolation() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let roomA = await runtime.createMeeting(title: "Room A", goal: "A")
        let roomB = await runtime.createMeeting(title: "Room B", goal: "B")

        for room in [roomA, roomB] {
            _ = try await runtime.addParticipant(
                meetingID: room.id,
                participant: Participant(
                    alias: "me",
                    displayName: "You",
                    provider: "human",
                    model: "human",
                    roles: [.host]
                )
            )
            _ = try await runtime.addParticipant(
                meetingID: room.id,
                participant: Participant(
                    alias: "claude-a",
                    displayName: "Claude A",
                    provider: "claude",
                    model: "claude-sonnet",
                    roles: [.planner]
                )
            )
            _ = try await runtime.addParticipant(
                meetingID: room.id,
                participant: Participant(
                    alias: "codex-r1",
                    displayName: "Codex R1",
                    provider: "codex",
                    model: "gpt-5",
                    roles: [.reviewer]
                )
            )
            _ = try await runtime.startMeeting(id: room.id)
        }

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { context in
                    let room = String(context.meeting.id.uuidString.lowercased().prefix(6))
                    return "\(participant.alias) from \(room)"
                },
                shutdown: {}
            )
        }
        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)

        try await orchestrator.setAutopilot(meetingID: roomA.id, enabled: true, intervalMilliseconds: 30)
        try await orchestrator.setAutopilot(meetingID: roomB.id, enabled: true, intervalMilliseconds: 30)
        try await Task.sleep(nanoseconds: 220_000_000)

        try await orchestrator.setAutopilot(meetingID: roomA.id, enabled: false)
        let roomBBefore = try await runtime.meeting(id: roomB.id)

        try await Task.sleep(nanoseconds: 180_000_000)
        let roomAAfterDisable = try await runtime.meeting(id: roomA.id)
        let roomAStableBaseline = roomAAfterDisable.messages.count
        try await Task.sleep(nanoseconds: 180_000_000)

        let roomAAfter = try await runtime.meeting(id: roomA.id)
        let roomBAfter = try await runtime.meeting(id: roomB.id)

        #expect(roomAAfter.messages.count == roomAStableBaseline)
        #expect(roomBAfter.messages.count > roomBBefore.messages.count)

        await orchestrator.stopAll()
    }

    @Test("Judge-gated policy alternates regular speaker and judge speaker")
    func judgeGatedOrder() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "Judge Gated", goal: "order")

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "me",
                displayName: "You",
                provider: "human",
                model: "human",
                roles: [.host]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "planner-ai",
                displayName: "Planner",
                provider: "claude",
                model: "claude-sonnet",
                roles: [.planner]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "reviewer-ai",
                displayName: "Reviewer",
                provider: "codex",
                model: "gpt-5",
                roles: [.reviewer]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "judge-ai",
                displayName: "Judge",
                provider: "codex",
                model: "gpt-5",
                roles: [.judge]
            )
        )
        _ = try await runtime.updatePolicy(
            meetingID: meeting.id,
            policy: MeetingPolicy(mode: .judgeGated, maxConcurrentAgents: 1, judgeAutoDecision: true)
        )
        _ = try await runtime.startMeeting(id: meeting.id)

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    "speak:\(participant.alias)"
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        _ = try await orchestrator.tick(meetingID: meeting.id, rounds: 4)

        let latest = try await runtime.meeting(id: meeting.id)
        #expect(latest.messages.map(\.fromAlias) == ["planner-ai", "judge-ai", "reviewer-ai", "judge-ai"])
    }

    @Test("Switching speaking mode during meeting applies on subsequent ticks")
    func switchSpeakingModeDuringMeeting() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "Switch Mode", goal: "runtime update")

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "me",
                displayName: "You",
                provider: "human",
                model: "human",
                roles: [.host]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "planner-ai",
                displayName: "Planner",
                provider: "claude",
                model: "claude-sonnet",
                roles: [.planner]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "reviewer-ai",
                displayName: "Reviewer",
                provider: "codex",
                model: "gpt-5",
                roles: [.reviewer]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "judge-ai",
                displayName: "Judge",
                provider: "codex",
                model: "gpt-5",
                roles: [.judge]
            )
        )
        _ = try await runtime.updatePolicy(
            meetingID: meeting.id,
            policy: MeetingPolicy(mode: .roundRobin, maxConcurrentAgents: 1, judgeAutoDecision: true)
        )
        _ = try await runtime.startMeeting(id: meeting.id)

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    "from:\(participant.alias)"
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        _ = try await orchestrator.tick(meetingID: meeting.id) // roundRobin => planner-ai

        _ = try await runtime.updatePolicy(
            meetingID: meeting.id,
            policy: MeetingPolicy(mode: .judgeGated, maxConcurrentAgents: 1, judgeAutoDecision: true)
        )
        _ = try await orchestrator.tick(meetingID: meeting.id, rounds: 3)

        let latest = try await runtime.meeting(id: meeting.id)
        #expect(latest.messages.map(\.fromAlias) == ["planner-ai", "planner-ai", "judge-ai", "reviewer-ai"])
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quorum-test-\(UUID().uuidString.lowercased()).db")
    }
}
