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
                    return AgentReplyOutput(content: "\(participant.alias) reply: \(last)")
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
                        return AgentReplyOutput(content: "decision: terminate\n收敛完成，终止会议。")
                    }
                    return AgentReplyOutput(content: "继续推进。")
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
                        return AgentReplyOutput(content: "decision: terminate\nI think we can stop.")
                    }
                    return AgentReplyOutput(content: "planner says continue")
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
                    return AgentReplyOutput(content: "\(participant.alias) from \(room)")
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
                    AgentReplyOutput(content: "speak:\(participant.alias)")
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
                    AgentReplyOutput(content: "from:\(participant.alias)")
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

    @Test("Host role is excluded from automatic speaker rotation")
    func hostRoleExcludedFromAutomaticRotation() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "Host Rotation", goal: "host should not auto speak")

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
                alias: "host-ai",
                displayName: "Host AI",
                provider: "codex",
                model: "gpt-5",
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
        _ = try await runtime.startMeeting(id: meeting.id)

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    AgentReplyOutput(content: "from:\(participant.alias)")
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        _ = try await orchestrator.tick(meetingID: meeting.id, rounds: 3)

        let latest = try await runtime.meeting(id: meeting.id)
        #expect(latest.messages.map(\.fromAlias) == ["planner-ai", "reviewer-ai", "planner-ai"])
    }

    @Test("Initial prompt sends full skill once, later turns are incremental and exclude own echo")
    func promptBootstrapsOnceThenUsesIncrementalMessages() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(
            title: "Prompt Cadence",
            goal: "ensure incremental prompt",
            defaultSkill: MeetingSkillDocument(name: "meeting-default", content: "MEETING-SKILL")
        )

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
                roles: [.planner],
                initialSkill: MeetingSkillDocument(name: "planner-initial", content: "PLANNER-SKILL")
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
        _ = try await runtime.startMeeting(id: meeting.id)

        _ = try await runtime.postMessage(
            meetingID: meeting.id,
            fromAlias: "me",
            toAliases: ["all"],
            content: "start"
        )

        actor TurnRecorder {
            private var contextsByAlias: [String: [AgentTurnContext]] = [:]
            private var turnCounterByAlias: [String: Int] = [:]

            func record(alias: String, context: AgentTurnContext) -> Int {
                contextsByAlias[alias, default: []].append(context)
                let nextTurn = (turnCounterByAlias[alias] ?? 0) + 1
                turnCounterByAlias[alias] = nextTurn
                return nextTurn
            }

            func contexts(alias: String) -> [AgentTurnContext] {
                contextsByAlias[alias] ?? []
            }
        }

        let recorder = TurnRecorder()
        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { context in
                    let turn = await recorder.record(alias: participant.alias, context: context)
                    return AgentReplyOutput(content: "reply:\(participant.alias)#\(turn)")
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        _ = try await orchestrator.tick(meetingID: meeting.id, rounds: 3)

        let plannerContexts = await recorder.contexts(alias: "planner-ai")
        #expect(plannerContexts.count == 2)

        let initialPrompt = plannerContexts[0].prompt
        #expect(initialPrompt.contains("Meeting default skill:"))
        #expect(initialPrompt.contains("MEETING-SKILL"))
        #expect(initialPrompt.contains("Your initial skill:"))
        #expect(initialPrompt.contains("PLANNER-SKILL"))

        let incrementalPrompt = plannerContexts[1].prompt
        #expect(incrementalPrompt.contains("New messages since your last turn"))
        #expect(!incrementalPrompt.contains("Meeting default skill:"))
        #expect(!incrementalPrompt.contains("PLANNER-SKILL"))
        #expect(!incrementalPrompt.contains("reply:planner-ai#1"))
        #expect(incrementalPrompt.contains("reply:reviewer-ai#1"))
        #expect(!plannerContexts[1].lastMessages.contains(where: { $0.fromAlias == "planner-ai" }))
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quorum-test-\(UUID().uuidString.lowercased()).db")
    }
}
