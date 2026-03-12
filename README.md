# Quorum

Swift-native starter project for multi-agent meetings.

## Structure

- `QuorumCore`: shared models and domain logic
- `QuorumCLI`: command-line entry point (`quorum`)
- `QuorumApp`: native macOS SwiftUI app shell

## Build

```bash
swift build
```

## Run CLI

```bash
swift run quorum
```

### CLI Quick Commands

```bash
create 支付重构评审会 --goal 确定技术方案
add --room <room-id-prefix> --provider human --model human --alias me --roles host,judge
add --room <room-id-prefix> --provider claude --model claude-sonnet --alias claude-a --roles planner
add --room <room-id-prefix> --provider codex --model gpt-5 --alias codex-r1 --roles reviewer
start --room <room-id-prefix>
say --room <room-id-prefix> --from me --to all "先给方案草案"
tick --room <room-id-prefix> --count 2
auto --room <room-id-prefix> --on --interval-ms 1200
policy --room <room-id-prefix>
policy --room <room-id-prefix> --mode judge-gated --judge-auto-decision on --max-concurrent-agents 1
status --room <room-id-prefix>
```

### Agent Executable Configuration

```bash
export MEET_AGENT_EXECUTABLE_CODEX="$(which codex)"
export MEET_AGENT_EXECUTABLE_CLAUDE="$HOME/.meeting/agents/claude-adapter"
export MEET_AGENT_EXECUTABLE_KIMI="$HOME/.meeting/agents/kimi-adapter"
```

## Open App in Xcode

```bash
open Package.swift
```
