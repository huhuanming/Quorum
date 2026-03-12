import Foundation
import QuorumCore

@main
struct QuorumCLI {
    private static let runtime = MeetingRuntime()
    private static let orchestrator = MeetingOrchestrator(runtime: runtime)

    static func main() async {
        if CommandLine.arguments.count > 1 {
            await runCommand(Array(CommandLine.arguments.dropFirst()))
            return
        }

        print("Quorum CLI REPL started. Type 'help' for commands, 'exit' to quit.")
        while true {
            print("quorum> ", terminator: "")
            guard let line = readLine() else { break }
            let tokens = tokenize(line)
            guard !tokens.isEmpty else { continue }
            if tokens[0] == "exit" || tokens[0] == "quit" {
                await orchestrator.stopAll()
                _ = await runtime.shutdown(reason: .cliStopped)
                print("Bye.")
                break
            }
            await runCommand(tokens)
        }
    }

    private static func runCommand(_ tokens: [String]) async {
        let command = tokens[0].lowercased()
        do {
            switch command {
            case "help":
                printHelp()
            case "create":
                try await handleCreate(tokens)
            case "list":
                await handleList()
            case "add":
                try await handleAdd(tokens)
            case "start":
                try await handleStart(tokens)
            case "say":
                try await handleSay(tokens)
            case "attach":
                try await handleAttach(tokens)
            case "status":
                try await handleStatus(tokens)
            case "stop":
                try await handleStop(tokens)
            case "tick":
                try await handleTick(tokens)
            case "auto":
                try await handleAuto(tokens)
            case "policy":
                try await handlePolicy(tokens)
            case "export":
                try await handleExport(tokens)
            default:
                print("Unknown command: \(command)")
                print("Use 'help' to see available commands.")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    private static func printHelp() {
        print("""
Available commands:
  create <title> [--goal <goal>]
  list
  add --room <id-prefix> --provider <provider> --model <model> --alias <alias> --roles <host,judge,...>
  start --room <id-prefix>
  say --room <id-prefix> --from <alias> --to <all|alias1,alias2> <content>
  attach --room <id-prefix> <absolute-path>
  status --room <id-prefix>
  stop --room <id-prefix>
  tick --room <id-prefix> [--count <n>]
  auto --room <id-prefix> --on [--interval-ms <ms>]
  auto --room <id-prefix> --off
  policy --room <id-prefix>
  policy --room <id-prefix> [--mode <round-robin|judge-gated|free>] [--judge-auto-decision <on|off>] [--max-concurrent-agents <n>]
  export --room <id-prefix> --out <absolute-path>
  exit
""")
    }

    private static func handleCreate(_ tokens: [String]) async throws {
        guard tokens.count >= 2 else {
            print("Usage: create <title> [--goal <goal>]")
            return
        }

        if let goalFlag = tokens.firstIndex(of: "--goal") {
            let titleTokens = Array(tokens[1 ..< goalFlag])
            guard goalFlag + 1 < tokens.count else {
                print("Usage: create <title> [--goal <goal>]")
                return
            }
            let goalTokens = Array(tokens[(goalFlag + 1)...])
            let meeting = await runtime.createMeeting(
                title: titleTokens.joined(separator: " "),
                goal: goalTokens.joined(separator: " ")
            )
            print("Created meeting id=\(short(meeting.id)) title=\(meeting.title)")
            return
        }

        let title = tokens.dropFirst().joined(separator: " ")
        let meeting = await runtime.createMeeting(title: title)
        print("Created meeting id=\(short(meeting.id)) title=\(meeting.title)")
    }

    private static func handleList() async {
        let meetings = await runtime.listMeetings()
        if meetings.isEmpty {
            print("No meetings.")
            return
        }

        print("Meetings:")
        for meeting in meetings {
            print("- id=\(short(meeting.id)) phase=\(meeting.phase.rawValue) title=\(meeting.title) participants=\(meeting.participants.count) messages=\(meeting.messages.count)")
        }
    }

    private static func handleAdd(_ tokens: [String]) async throws {
        guard
            let roomPrefix = value(after: "--room", in: tokens),
            let provider = value(after: "--provider", in: tokens),
            let model = value(after: "--model", in: tokens),
            let alias = value(after: "--alias", in: tokens),
            let rolesRaw = value(after: "--roles", in: tokens)
        else {
            print("Usage: add --room <id-prefix> --provider <provider> --model <model> --alias <alias> --roles <host,judge,...>")
            return
        }

        let roles = rolesRaw
            .split(separator: ",")
            .compactMap { ParticipantRole(rawValue: String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }

        let participant = Participant(
            alias: alias,
            displayName: alias,
            provider: provider,
            model: model,
            roles: roles
        )

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let meeting = try await runtime.addParticipant(meetingID: meetingID, participant: participant)
        print("Added participant @\(alias) to \(short(meeting.id)) (count=\(meeting.participants.count))")
    }

    private static func handleStart(_ tokens: [String]) async throws {
        guard let roomPrefix = value(after: "--room", in: tokens) else {
            print("Usage: start --room <id-prefix>")
            return
        }
        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let started = try await runtime.startMeeting(id: meetingID)
        print("Started meeting id=\(short(started.id)) phase=\(started.phase.rawValue)")
    }

    private static func handleSay(_ tokens: [String]) async throws {
        guard
            let roomPrefix = value(after: "--room", in: tokens),
            let fromAlias = value(after: "--from", in: tokens),
            let toRaw = value(after: "--to", in: tokens),
            let toIndex = tokens.firstIndex(of: "--to"),
            toIndex + 2 <= tokens.count
        else {
            print("Usage: say --room <id-prefix> --from <alias> --to <all|a,b> <content>")
            return
        }

        let contentTokens = Array(tokens[(toIndex + 2)...])
        let content = contentTokens.joined(separator: " ")
        let toAliases = toRaw.split(separator: ",").map { String($0) }

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let message = try await runtime.postMessage(
            meetingID: meetingID,
            fromAlias: fromAlias,
            toAliases: toAliases,
            content: content
        )
        print("Message sent id=\(short(message.id)) from=@\(message.fromAlias)")
    }

    private static func handleAttach(_ tokens: [String]) async throws {
        guard
            let roomPrefix = value(after: "--room", in: tokens),
            let path = tokens.last,
            !path.hasPrefix("--")
        else {
            print("Usage: attach --room <id-prefix> <absolute-path>")
            return
        }

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let attachment = try await runtime.attachPath(meetingID: meetingID, path: path)
        print("Attached \(attachment.kind.rawValue): \(attachment.path)")
    }

    private static func handleStatus(_ tokens: [String]) async throws {
        guard let roomPrefix = value(after: "--room", in: tokens) else {
            print("Usage: status --room <id-prefix>")
            return
        }

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let meeting = try await runtime.meeting(id: meetingID)
        print("Meeting \(short(meeting.id))")
        print("  title=\(meeting.title)")
        print("  phase=\(meeting.phase.rawValue)")
        print("  participants=\(meeting.participants.count)")
        print("  messages=\(meeting.messages.count)")
        print("  attachments=\(meeting.attachments.count)")
        let autopilot = await orchestrator.autopilotEnabled(meetingID: meeting.id)
        print("  autopilot=\(autopilot ? "on" : "off")")
        print("  policy.mode=\(meeting.policy.mode.rawValue)")
        print("  policy.judge_auto_decision=\(meeting.policy.judgeAutoDecision ? "on" : "off")")
        print("  policy.max_concurrent_agents=\(meeting.policy.maxConcurrentAgents)")
        if let reason = meeting.terminationReason {
            print("  termination_reason=\(reason.rawValue)")
        }
    }

    private static func handleStop(_ tokens: [String]) async throws {
        guard let roomPrefix = value(after: "--room", in: tokens) else {
            print("Usage: stop --room <id-prefix>")
            return
        }

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let stopped = try await runtime.stopMeeting(id: meetingID, reason: .manualStop)
        try? await orchestrator.setAutopilot(meetingID: stopped.id, enabled: false)
        print("Stopped meeting id=\(short(stopped.id))")
    }

    private static func handleTick(_ tokens: [String]) async throws {
        guard let roomPrefix = value(after: "--room", in: tokens) else {
            print("Usage: tick --room <id-prefix> [--count <n>]")
            return
        }

        let rounds: Int
        if let countRaw = value(after: "--count", in: tokens), let parsed = Int(countRaw), parsed > 0 {
            rounds = parsed
        } else {
            rounds = 1
        }

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let messages = try await orchestrator.tick(meetingID: meetingID, rounds: rounds)
        if messages.isEmpty {
            print("No messages generated.")
            return
        }
        for message in messages {
            print("[tick] @\(message.fromAlias): \(message.content)")
        }
    }

    private static func handleAuto(_ tokens: [String]) async throws {
        guard let roomPrefix = value(after: "--room", in: tokens) else {
            print("Usage: auto --room <id-prefix> --on [--interval-ms <ms>] | --off")
            return
        }
        let meetingID = try await resolveMeetingID(prefix: roomPrefix)

        let hasOn = tokens.contains("--on")
        let hasOff = tokens.contains("--off")
        if hasOn == hasOff {
            print("Usage: auto --room <id-prefix> --on [--interval-ms <ms>] | --off")
            return
        }

        if hasOn {
            let intervalMS: UInt64
            if let raw = value(after: "--interval-ms", in: tokens),
               let parsed = UInt64(raw), parsed > 0
            {
                intervalMS = parsed
            } else {
                intervalMS = 1200
            }
            try await orchestrator.setAutopilot(meetingID: meetingID, enabled: true, intervalMilliseconds: intervalMS)
            print("Autopilot enabled for \(short(meetingID)) interval=\(intervalMS)ms")
            return
        }

        try await orchestrator.setAutopilot(meetingID: meetingID, enabled: false)
        print("Autopilot disabled for \(short(meetingID))")
    }

    private static func handleExport(_ tokens: [String]) async throws {
        guard
            let roomPrefix = value(after: "--room", in: tokens),
            let outPath = value(after: "--out", in: tokens)
        else {
            print("Usage: export --room <id-prefix> --out <absolute-path>")
            return
        }

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let markdown = try await runtime.exportMeetingMarkdown(id: meetingID)
        try markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
        print("Exported: \(outPath)")
    }

    private static func handlePolicy(_ tokens: [String]) async throws {
        guard let roomPrefix = value(after: "--room", in: tokens) else {
            print("Usage: policy --room <id-prefix> [--mode <round-robin|judge-gated|free>] [--judge-auto-decision <on|off>] [--max-concurrent-agents <n>]")
            return
        }

        let meetingID = try await resolveMeetingID(prefix: roomPrefix)
        let meeting = try await runtime.meeting(id: meetingID)
        let hasMode = tokens.contains("--mode")
        let hasJudge = tokens.contains("--judge-auto-decision")
        let hasMaxConcurrent = tokens.contains("--max-concurrent-agents")
        if !hasMode, !hasJudge, !hasMaxConcurrent {
            print("Policy for \(short(meeting.id))")
            print("  mode=\(meeting.policy.mode.rawValue)")
            print("  judge_auto_decision=\(meeting.policy.judgeAutoDecision ? "on" : "off")")
            print("  max_concurrent_agents=\(meeting.policy.maxConcurrentAgents)")
            return
        }

        var nextMode = meeting.policy.mode
        var nextJudgeAutoDecision = meeting.policy.judgeAutoDecision
        var nextMaxConcurrentAgents = meeting.policy.maxConcurrentAgents

        if let modeRaw = value(after: "--mode", in: tokens) {
            guard let parsed = meetingMode(from: modeRaw) else {
                print("Unsupported mode: \(modeRaw). Use round-robin | judge-gated | free")
                return
            }
            nextMode = parsed
        } else if hasMode {
            print("Usage: --mode <round-robin|judge-gated|free>")
            return
        }

        if let judgeRaw = value(after: "--judge-auto-decision", in: tokens) {
            guard let parsed = boolValue(from: judgeRaw) else {
                print("Unsupported judge-auto-decision value: \(judgeRaw). Use on|off")
                return
            }
            nextJudgeAutoDecision = parsed
        } else if hasJudge {
            print("Usage: --judge-auto-decision <on|off>")
            return
        }

        if let maxRaw = value(after: "--max-concurrent-agents", in: tokens) {
            guard let parsed = Int(maxRaw), parsed > 0 else {
                print("max-concurrent-agents must be a positive integer")
                return
            }
            nextMaxConcurrentAgents = parsed
        } else if hasMaxConcurrent {
            print("Usage: --max-concurrent-agents <n>")
            return
        }

        let updated = try await runtime.updatePolicy(
            meetingID: meetingID,
            policy: MeetingPolicy(
                mode: nextMode,
                maxConcurrentAgents: nextMaxConcurrentAgents,
                judgeAutoDecision: nextJudgeAutoDecision
            )
        )
        print("Updated policy for \(short(updated.id))")
        print("  mode=\(updated.policy.mode.rawValue)")
        print("  judge_auto_decision=\(updated.policy.judgeAutoDecision ? "on" : "off")")
        print("  max_concurrent_agents=\(updated.policy.maxConcurrentAgents)")
    }

    private static func resolveMeetingID(prefix: String) async throws -> UUID {
        let meetings = await runtime.listMeetings()
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw NSError(domain: "QuorumCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty room id prefix"])
        }

        let matches = meetings.filter { meeting in
            meeting.id.uuidString.lowercased().hasPrefix(trimmed)
        }

        if matches.isEmpty {
            throw NSError(domain: "QuorumCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "No room found for prefix: \(prefix)"])
        }
        if matches.count > 1 {
            throw NSError(domain: "QuorumCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Ambiguous room prefix: \(prefix)"])
        }
        return matches[0].id
    }

    private static func value(after flag: String, in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else {
            return nil
        }
        return tokens[index + 1]
    }

    private static func meetingMode(from raw: String) -> MeetingSpeakingMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "round-robin", "round_robin", "roundrobin":
            return .roundRobin
        case "judge-gated", "judge_gated", "judgegated":
            return .judgeGated
        case "free":
            return .free
        default:
            return nil
        }
    }

    private static func boolValue(from raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "true", "1", "yes":
            return true
        case "off", "false", "0", "no":
            return false
        default:
            return nil
        }
    }

    private static func short(_ id: UUID) -> String {
        String(id.uuidString.lowercased().prefix(8))
    }

    // Lightweight shell-style tokenizer with support for quoted strings.
    private static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
