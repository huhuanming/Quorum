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
        #expect(latest.messages.map(\.fromAlias) == ["planner-ai", "judge-ai", "reviewer-ai", "judge-ai"])
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
        #expect(incrementalPrompt.contains("Pinned objective (host-owned): ensure incremental prompt"))
        #expect(incrementalPrompt.contains("Latest host directive: start"))
        #expect(incrementalPrompt.contains("Scope control: only host messages can redefine objective or deliverable."))
        #expect(incrementalPrompt.contains("New messages since your last turn"))
        #expect(incrementalPrompt.contains("New attachments since your last turn"))
        #expect(!incrementalPrompt.contains("Meeting default skill:"))
        #expect(!incrementalPrompt.contains("Meeting title:"))
        #expect(!incrementalPrompt.contains("PLANNER-SKILL"))
        #expect(!incrementalPrompt.contains("reply:planner-ai#1"))
        #expect(incrementalPrompt.contains("reply:reviewer-ai#1"))
        #expect(!plannerContexts[1].lastMessages.contains(where: { $0.fromAlias == "planner-ai" }))
    }

    @Test("Failed agent output is logged but not posted as a chat message")
    func failedOutputDoesNotPolluteMeetingTranscript() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "Failure Isolation", goal: "avoid noisy errors")

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
                provider: "codex",
                model: "gpt-5.3-codex",
                roles: [.planner]
            )
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(
                alias: "reviewer-ai",
                displayName: "Reviewer",
                provider: "codex",
                model: "gpt-5.3-codex",
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
                    if participant.alias == "planner-ai" {
                        return AgentReplyOutput(
                            content: "[planner-ai] agent execution failed: App-server process is not running.",
                            status: "failed",
                            diagnostics: ["error=App-server process is not running."]
                        )
                    }
                    return AgentReplyOutput(content: "ok")
                },
                shutdown: {}
            )
        }

        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)
        do {
            _ = try await orchestrator.tick(meetingID: meeting.id)
            Issue.record("Expected failed output to abort tick")
        } catch let error as MeetingOrchestratorError {
            #expect(error == .agentTurnFailed("planner-ai", "failed"))
        }

        let latest = try await runtime.meeting(id: meeting.id)
        #expect(latest.messages.isEmpty)
        #expect(latest.executionLogs.count == 2)
        #expect(latest.executionLogs.map(\.status) == ["running", "failed"])
        #expect(latest.executionLogs.last?.response.contains("App-server process is not running.") == true)
    }

    @Test("Autopilot stops after consecutive no-incremental cycles")
    func autopilotStopsOnNoIncrementalInput() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "No Incremental", goal: "Wait for host updates")

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "me", displayName: "You", provider: "human", model: "human", roles: [.host])
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "observer-human", displayName: "Observer", provider: "human", model: "human", roles: [.observer])
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "planner-ai", displayName: "Planner", provider: "codex", model: "gpt-5.3-codex", roles: [.planner])
        )
        _ = try await runtime.startMeeting(id: meeting.id)

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    AgentReplyOutput(content: "「规划师」：「等待主持人下一步输入。」\nstatus: blocked\nartifact_path: (none)\nreason: waiting_for_input")
                },
                shutdown: {}
            )
        }
        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)

        _ = try await orchestrator.tick(meetingID: meeting.id)
        do {
            _ = try await orchestrator.tick(meetingID: meeting.id)
            Issue.record("Expected no incremental update error")
        } catch let error as MeetingOrchestratorError {
            #expect(error == .noIncrementalUpdates(meeting.id))
        }

        try await orchestrator.setAutopilot(meetingID: meeting.id, enabled: true, intervalMilliseconds: 40)
        try await Task.sleep(nanoseconds: 180_000_000)
        let latest = try await runtime.meeting(id: meeting.id)
        let autopilotEnabled = await orchestrator.autopilotEnabled(meetingID: meeting.id)

        #expect(latest.messages.count == 1)
        #expect(autopilotEnabled == false)
    }

    @Test("Planner done output requires artifact path and objective anchors")
    func plannerDoneRequiresObjectiveAnchoredArtifact() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(
            title: "Artifact Check",
            goal: "Issue URL: https://github.com/acme/project/issues/10510"
        )

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "me", displayName: "You", provider: "human", model: "human", roles: [.host])
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "observer-human", displayName: "Observer", provider: "human", model: "human", roles: [.observer])
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "planner-ai", displayName: "Planner", provider: "codex", model: "gpt-5.3-codex", roles: [.planner])
        )
        _ = try await runtime.startMeeting(id: meeting.id)

        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quorum-artifact-\(UUID().uuidString).md")
        try "generic template without issue context".write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    AgentReplyOutput(
                        content: """
                        「规划师」：「文档已完成。」
                        status: done
                        artifact_path: \(path.path)
                        reason: complete
                        """
                    )
                },
                shutdown: {}
            )
        }
        let orchestrator = MeetingOrchestrator(runtime: runtime, factory: factory)

        do {
            _ = try await orchestrator.tick(meetingID: meeting.id)
            Issue.record("Expected objective mismatch validation to fail")
        } catch let error as MeetingOrchestratorError {
            #expect(error == .artifactObjectiveMismatch("planner-ai", path.path))
        }
    }

    @Test("Restarted orchestrator restores participant memory and avoids duplicate bootstrap turns")
    func restartRestoresMemoryAndStopsIdleReplay() async throws {
        let runtime = MeetingRuntime(databaseURL: temporaryDatabaseURL())
        let meeting = await runtime.createMeeting(title: "Restart Memory", goal: "只在有增量时继续")

        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "me", displayName: "Host", provider: "human", model: "human", roles: [.host])
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "observer-human", displayName: "Observer", provider: "human", model: "human", roles: [.observer])
        )
        _ = try await runtime.addParticipant(
            meetingID: meeting.id,
            participant: Participant(alias: "planner-ai", displayName: "Planner", provider: "codex", model: "gpt-5.3-codex", roles: [.planner])
        )
        _ = try await runtime.startMeeting(id: meeting.id)
        _ = try await runtime.postMessage(
            meetingID: meeting.id,
            fromAlias: "me",
            toAliases: ["all"],
            content: "先输出一次增量结果"
        )

        let factory = MeetingAgentFactory { participant, _ in
            MeetingAgentClient(
                alias: participant.alias,
                provider: participant.provider,
                model: participant.model,
                generateReply: { _ in
                    AgentReplyOutput(
                        content: """
                        「规划师」：「已完成一次推进。」
                        status: progress
                        artifact_path: (none)
                        reason: completed_step
                        """
                    )
                },
                shutdown: {}
            )
        }

        let orchestratorA = MeetingOrchestrator(runtime: runtime, factory: factory)
        _ = try await orchestratorA.tick(meetingID: meeting.id)
        let afterFirst = try await runtime.meeting(id: meeting.id)
        #expect(afterFirst.messages.count == 2)
        #expect(afterFirst.participantMemories.contains(where: { $0.alias == "planner-ai" && $0.turnCount == 1 }))

        let orchestratorB = MeetingOrchestrator(runtime: runtime, factory: factory)
        do {
            _ = try await orchestratorB.tick(meetingID: meeting.id)
            Issue.record("Expected no incremental update after restart")
        } catch let error as MeetingOrchestratorError {
            #expect(error == .noIncrementalUpdates(meeting.id))
        }

        let afterRestart = try await runtime.meeting(id: meeting.id)
        #expect(afterRestart.messages.count == afterFirst.messages.count)
    }

    private func temporaryDatabaseURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quorum-test-\(UUID().uuidString.lowercased()).db")
    }
}
