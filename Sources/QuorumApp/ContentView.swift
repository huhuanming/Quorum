import SwiftUI
import UniformTypeIdentifiers
import AppKit
import QuorumCore

private enum UIMotion {
    static let standard: Double = 0.2
}

private enum ChatBubbleStyle: String, CaseIterable, Identifiable {
    case chatty
    case slacky
    case compact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatty:
            return "Chatty"
        case .slacky:
            return "Slacky"
        case .compact:
            return "Compact"
        }
    }

    var groupedTimeWindow: TimeInterval {
        switch self {
        case .chatty:
            return 5 * 60
        case .slacky:
            return 3 * 60
        case .compact:
            return 2 * 60
        }
    }

    var groupedTopSpacing: CGFloat {
        switch self {
        case .chatty:
            return 5
        case .slacky:
            return 3
        case .compact:
            return 2
        }
    }

    var bubbleLargeCorner: CGFloat {
        switch self {
        case .chatty:
            return 18
        case .slacky:
            return 12
        case .compact:
            return 9
        }
    }

    var bubbleSmallCorner: CGFloat {
        switch self {
        case .chatty:
            return 7
        case .slacky:
            return 4
        case .compact:
            return 3
        }
    }

    var summary: String {
        switch self {
        case .chatty:
            return "更圆润，分组更宽松"
        case .slacky:
            return "更紧凑，信息密度更高"
        case .compact:
            return "最紧凑，适合高频讨论"
        }
    }
}

struct ContentView: View {
    @State private var store = MeetingWorkspaceStore()
    @State private var showingCreateMeetingSheet = false
    @State private var showingPolicySheet = false
    @State private var showingInspector = true
    @State private var showingAttachmentTray = false
    @AppStorage("quorum.chat.bubbleStyle") private var bubbleStyleRawValue: String = ChatBubbleStyle.chatty.rawValue
    @AppStorage("quorum.chat.bubbleStyle.meetingOverrides") private var bubbleStyleMeetingOverridesRawValue: String = "{}"
    @State private var createDraft = MeetingCreationDraft.defaultValue
    @State private var policyDraft = MeetingPolicyDraft.defaultValue
    @State private var createMeetingError: String?
    @State private var policySaveError: String?
    @State private var isCreatingMeeting = false
    @State private var isSavingPolicy = false
    @State private var showingSkillFileImporter = false
    @State private var skillImportError: String?
    @State private var participantLogSelection: ParticipantLogSelection?
    @State private var skillPreviewSelection: SkillPreviewSelection?
    @State private var messageIDsShowingTimestamp: Set<UUID> = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .preferredColorScheme(nil)
        .sheet(isPresented: $showingCreateMeetingSheet) {
            createMeetingSheet
        }
        .sheet(isPresented: $showingPolicySheet) {
            policySheet
        }
        .sheet(item: $participantLogSelection, onDismiss: {
            participantLogSelection = nil
        }) { selection in
            participantExecutionLogSheet(selection: selection)
        }
        .fileImporter(
            isPresented: $showingSkillFileImporter,
            allowedContentTypes: [.plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            importSkillFiles(result)
        }
    }

    private var sidebar: some View {
        ZStack {
            LinearGradient(
                colors: palette.sidebarGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Quorum")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white)
                    Text("Multi-agent meeting workspace")
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Button {
                    openCreateMeetingPanel()
                } label: {
                    Label("新建会议", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(sidebarMeetings, id: \.id) { meeting in
                            HStack(spacing: 8) {
                                Button {
                                    store.selectMeeting(meeting.id)
                                } label: {
                                    MeetingListRow(
                                        meeting: meeting,
                                        unreadCount: store.unreadByRoom[meeting.id, default: 0],
                                        isActive: store.activeMeetingID == meeting.id
                                    )
                                }
                                .buttonStyle(.plain)

                                Button(role: .destructive) {
                                    store.deleteMeeting(meeting.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.subheadline)
                                        .foregroundStyle(Color.white.opacity(0.9))
                                        .frame(width: 30, height: 30)
                                        .background(Color.white.opacity(0.12))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("删除会议")
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private var sidebarMeetings: [Meeting] {
        store.meetings.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            // Keep chronological order so newest meetings appear at the bottom.
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var detail: some View {
        ZStack {
            LinearGradient(
                colors: palette.canvasGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if store.isBootstrapping, store.meetings.isEmpty {
                loadingState
            } else if let activeMeeting = store.activeMeeting {
                VStack(spacing: 12) {
                    meetingTopBar(meeting: activeMeeting)
                    feedbackBanner

                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            meetingSummary(meeting: activeMeeting)
                            chatTimeline(meeting: activeMeeting)
                            composer
                        }

                        if showingInspector {
                            meetingInspector(meeting: activeMeeting)
                                .frame(minWidth: 280, maxWidth: 330)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                .padding(14)
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private var feedbackBanner: some View {
        if let error = store.lastError {
            StatusBanner(
                text: error,
                tone: .error,
                actionTitle: "关闭",
                action: { store.clearError() },
                palette: palette
            )
        } else if let status = store.lastActionStatus {
            StatusBanner(
                text: status,
                tone: .success,
                actionTitle: nil,
                action: nil,
                palette: palette
            )
        }
    }

    private var loadingState: some View {
        StateCard(
            icon: "hourglass",
            title: "正在加载会议",
            subtitle: "请稍候，马上就好",
            actionTitle: nil,
            action: nil,
            palette: palette
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private var emptyState: some View {
        StateCard(
            icon: "person.3.sequence.fill",
            title: "暂无活跃会议",
            subtitle: "从左侧选择会议，或创建一个新的讨论房间",
            actionTitle: "新建会议",
            action: { openCreateMeetingPanel() },
            palette: palette
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func meetingTopBar(meeting: Meeting) -> some View {
        let autopilotOn = store.autopilotByRoom[meeting.id, default: false]
        let running = meeting.phase == .running
        let ended = meeting.phase == .ended
        let primaryBusy = running ? store.isRunningRound : store.isStartingMeeting
        let stopBusy = store.isStoppingMeeting
        let autoBusy = store.isTogglingAutopilot
        let anyBusy = primaryBusy || autoBusy || stopBusy
        let primaryTitle = primaryBusy
            ? (running ? "执行中..." : "启动中...")
            : (ended ? "Ended" : (running ? "Round" : "Start"))
        let autoTitle = autoBusy ? "Auto..." : (autopilotOn ? "Auto On" : "Auto Off")

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                Text("\(meeting.participants.count) people")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            Spacer()

            Text(meeting.phase.rawValue.uppercased())
                .font(.caption.bold())
                .foregroundStyle(running ? Color.green : (ended ? Color.red : palette.textSecondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.chipBackground)
                .clipShape(Capsule())

            Button(primaryTitle) {
                if running {
                    store.runOneAgentRound()
                } else if !ended {
                    store.startActiveMeetingIfNeeded()
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(running || ended ? palette.textPrimary : .white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(running || ended ? palette.chipBackground : palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .disabled(primaryBusy || stopBusy || autoBusy || ended)

            Button(autoTitle) {
                if running {
                    store.toggleAutopilot()
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(autopilotOn ? .white : palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(autopilotOn ? Color.green : palette.chipBackground)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .disabled(!running || autoBusy || stopBusy || primaryBusy)

            if anyBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                withAnimation(.easeInOut(duration: UIMotion.standard)) {
                    showingInspector.toggle()
                }
            } label: {
                Label(showingInspector ? "隐藏面板" : "显示面板", systemImage: "sidebar.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.chipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Menu {
                Button("复制配置为新会议") {
                    openCreateMeetingPanel(copying: meeting)
                }
                Button("复制会议 ID") {
                    copyMeetingID(meeting.id)
                }
                Button("会议策略") {
                    openPolicySheet(meeting: meeting)
                }
                Button("结束会议", role: .destructive) {
                    if running {
                        store.stopActiveMeeting()
                    }
                }
                .disabled(!running || anyBusy)
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.chipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
            }
            .menuStyle(.borderlessButton)
        }
        .padding(16)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func meetingSummary(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(meeting.goal.isEmpty ? "未设置会议目标" : meeting.goal)
                .font(.subheadline)
                .foregroundStyle(meeting.goal.isEmpty ? palette.textSecondary : palette.textPrimary)
                .lineLimit(2)

            HStack(spacing: 8) {
                infoChip("策略", value: meeting.policy.mode.displayName)
                infoChip("并发", value: "\(meeting.policy.maxConcurrentAgents)")
                infoChip("自动判决", value: meeting.policy.judgeAutoDecision ? "开" : "关")
            }

            if meeting.phase == .ended {
                meetingOutcomeCard(meeting: meeting)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func meetingOutcomeCard(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "flag.checkered.circle.fill")
                    .foregroundStyle(Color.red)
                Text("会议已结束")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.textPrimary)
            }

            if let terminationReason = meeting.terminationReason {
                Text("结束原因：\(terminationReason.displayName)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            if let judgeDecision = meeting.judgeDecision {
                Text("裁判结论：\(judgeDecision.displayName)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
            if let endedAt = meeting.endedAt {
                Text("结束时间：\(endedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.chipBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func meetingInspector(meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("会议面板")
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Text("策略设置")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                infoChip("发言模式", value: meeting.policy.mode.displayName)
                infoChip("最大并发", value: "\(meeting.policy.maxConcurrentAgents)")
                infoChip("裁判自动判决", value: meeting.policy.judgeAutoDecision ? "开启" : "关闭")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("聊天风格")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)

                Picker("全局默认", selection: globalBubbleStyleSelection) {
                    ForEach(ChatBubbleStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Picker("当前会议", selection: meetingBubbleStyleSelection(for: meeting.id)) {
                    Text("跟随全局").tag("global")
                    ForEach(ChatBubbleStyle.allCases) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                .pickerStyle(.menu)

                let activeStyle = resolvedBubbleStyle(for: meeting.id)
                Text("当前生效：\(activeStyle.displayName) · \(activeStyle.summary)")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            Divider()

            Text("参会者")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(meeting.participants, id: \.alias) { participant in
                        Button {
                            participantLogSelection = ParticipantLogSelection(
                                meetingID: meeting.id,
                                participantAlias: participant.alias
                            )
                        } label: {
                            HStack(alignment: .center, spacing: 8) {
                                Text(participant.resolvedAvatarEmoji)
                                    .font(.title3)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(participant.displayName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(palette.textPrimary)
                                        .lineLimit(1)
                                    Text("@\(participant.alias) · \(participant.model)")
                                        .font(.caption)
                                        .foregroundStyle(palette.textSecondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text("日志")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(palette.chipBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }

    private func participantExecutionLogSheet(selection: ParticipantLogSelection) -> some View {
        let meeting = store.meetings.first(where: { $0.id == selection.meetingID })
        let participant = meeting?.participants.first(where: {
            $0.alias.caseInsensitiveCompare(selection.participantAlias) == .orderedSame
        })
        let allLogs = meeting?
            .executionLogs
            .filter { $0.participantAlias.caseInsensitiveCompare(selection.participantAlias) == .orderedSame }
            .sorted { $0.createdAt > $1.createdAt } ?? []
        let maxVisibleLogs = 40
        let logs = Array(allLogs.prefix(maxVisibleLogs))
        let promptPreviewLimit = 4_000
        let responsePreviewLimit = 4_000
        let diagnosticsPreviewLimit = 4_000

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("执行日志")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Button("关闭") {
                    participantLogSelection = nil
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(palette.chipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .keyboardShortcut(.cancelAction)
            }

            if let participant {
                Text("\(participant.displayName) · @\(participant.alias) · \(participant.model)")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
            } else {
                Text("@\(selection.participantAlias)")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
            }

            if allLogs.count > logs.count {
                Text("为保证流畅度，仅展示最近 \(logs.count) 条日志（共 \(allLogs.count) 条）。")
                    .font(.caption)
                    .foregroundStyle(palette.textSecondary)
            }

            if logs.isEmpty {
                Text("暂无执行日志。先运行一轮 Agent 后再查看。")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(logs, id: \.id) { log in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(log.createdAt.formatted(date: .abbreviated, time: .standard)) · \(log.status)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(palette.textSecondary)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Prompt")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.textSecondary)
                                    Text(log.prompt.truncatedForLogPreview(limit: promptPreviewLimit))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(palette.textPrimary)
                                        .textSelection(.enabled)
                                    if log.prompt.count > promptPreviewLimit {
                                        Text("内容较长，已截断显示。")
                                            .font(.caption2)
                                            .foregroundStyle(palette.textSecondary)
                                    }
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Response")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.textSecondary)
                                    Text(log.response.truncatedForLogPreview(limit: responsePreviewLimit))
                                        .font(.caption)
                                        .foregroundStyle(palette.textPrimary)
                                        .textSelection(.enabled)
                                    if log.response.count > responsePreviewLimit {
                                        Text("内容较长，已截断显示。")
                                            .font(.caption2)
                                            .foregroundStyle(palette.textSecondary)
                                    }
                                }

                                if !log.diagnostics.isEmpty {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Diagnostics")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(palette.textSecondary)
                                        Text(log.diagnostics.joined(separator: "\n").truncatedForLogPreview(limit: diagnosticsPreviewLimit))
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(palette.textSecondary)
                                            .textSelection(.enabled)
                                        if log.diagnostics.joined(separator: "\n").count > diagnosticsPreviewLimit {
                                            Text("内容较长，已截断显示。")
                                                .font(.caption2)
                                                .foregroundStyle(palette.textSecondary)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(palette.chipBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(minWidth: 840, minHeight: 520)
        .background(
            LinearGradient(
                colors: palette.canvasGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .interactiveDismissDisabled(false)
    }

    private func openSkillPreview(template: MeetingSkillTemplateDraft, header: String) {
        skillPreviewSelection = SkillPreviewSelection(
            header: header,
            name: template.name,
            content: template.content,
            source: template.source,
            filePath: template.filePath
        )
    }

    private func skillPreviewSheet(selection: SkillPreviewSelection) -> some View {
        let filePath = selection.filePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasFilePath = !(filePath ?? "").isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selection.header)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Button("关闭") {
                    skillPreviewSelection = nil
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(palette.chipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .keyboardShortcut(.cancelAction)
            }

            Text("\(selection.name) · \(selection.source.displayName)")
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)

            if hasFilePath, let filePath {
                HStack(spacing: 8) {
                    Text(filePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("在 Finder 打开") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(palette.chipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            ScrollView {
                Text(selection.content)
                    .font(.body.monospaced())
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(palette.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(18)
        .frame(minWidth: 900, minHeight: 620)
        .background(
            LinearGradient(
                colors: palette.canvasGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .interactiveDismissDisabled(false)
    }

    private func infoChip(_ title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(palette.chipBackground)
        .clipShape(Capsule())
    }

    private var policySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("会议策略")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
            }

            Picker("发言模式", selection: $policyDraft.speakingMode) {
                ForEach(MeetingSpeakingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("裁判自动判决", isOn: $policyDraft.judgeAutoDecision)
                .toggleStyle(.switch)

            Stepper(value: $policyDraft.maxConcurrentAgents, in: 1 ... 8) {
                Text("最大并发 Agent: \(policyDraft.maxConcurrentAgents)")
                    .font(.subheadline)
                    .foregroundStyle(palette.textSecondary)
            }

            if let message = policySaveError ?? policyDraft.validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.9))
                    .clipShape(Capsule())
            }

            HStack {
                Spacer()
                Button("取消") {
                    showingPolicySheet = false
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.chipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button(isSavingPolicy ? "保存中..." : "保存") {
                    savePolicyDraft()
                }
                .buttonStyle(.plain)
                .disabled(isSavingPolicy || policyDraft.validationMessage != nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(18)
        .frame(minWidth: 560, minHeight: 260)
        .background(
            LinearGradient(
                colors: palette.canvasGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var createMeetingSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("会议配置")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
            }

            HStack(spacing: 10) {
                TextField("会议标题", text: $createDraft.title)
                    .textFieldStyle(.roundedBorder)
                Toggle("创建后立即开始", isOn: $createDraft.autoStart)
                    .toggleStyle(.switch)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("会议描述")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                TextEditor(text: $createDraft.goal)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 92)
                    .padding(8)
                    .background(palette.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("会议 Skill")
                    .font(.headline)

                HStack(spacing: 8) {
                    Picker("默认 skill", selection: $createDraft.meetingDefaultSkillTemplateID) {
                        ForEach(createDraft.allSkillTemplates) { skill in
                            Text(skill.name).tag(skill.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if let selected = createDraft.selectedMeetingDefaultSkillTemplate {
                        Button("打开预览") {
                            openSkillPreview(template: selected, header: "会议默认 Skill")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(palette.chipBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                Text("默认 skill 预览")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                Text(createDraft.selectedMeetingDefaultSkillTemplate?.content ?? "(none)")
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(palette.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        showingSkillFileImporter = true
                        skillImportError = nil
                    } label: {
                        Label("导入额外 skill 文件", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)

                    if let error = skillImportError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }

                if !createDraft.importedSkillTemplates.isEmpty {
                    Text("已导入 skill（勾选表示注入到会议上下文）")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.textSecondary)

                    ForEach(createDraft.importedSkillTemplates) { skill in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Toggle(
                                    skill.name,
                                    isOn: Binding(
                                        get: { createDraft.selectedAdditionalSkillTemplateIDs.contains(skill.id) },
                                        set: { enabled in
                                            if enabled {
                                                createDraft.selectedAdditionalSkillTemplateIDs.insert(skill.id)
                                            } else {
                                                createDraft.selectedAdditionalSkillTemplateIDs.remove(skill.id)
                                            }
                                        }
                                    )
                                )
                                .toggleStyle(.checkbox)

                                Button("预览") {
                                    openSkillPreview(template: skill, header: "导入 Skill")
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(palette.chipBackground)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                                Button(role: .destructive) {
                                    createDraft.removeImportedSkillTemplate(skill.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }

                            Text(skill.content)
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .padding(12)
            .background(palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("会议策略")
                    .font(.headline)
                Picker("发言模式", selection: $createDraft.speakingMode) {
                    ForEach(MeetingSpeakingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 16) {
                    Toggle("裁判自动判决", isOn: $createDraft.judgeAutoDecision)
                        .toggleStyle(.switch)
                    Stepper(value: $createDraft.maxConcurrentAgents, in: 1 ... 8) {
                        Text("最大并发 Agent: \(createDraft.maxConcurrentAgents)")
                            .font(.subheadline)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            .padding(12)
            .background(palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )

            HStack {
                Text("参会者")
                    .font(.headline)
                Spacer()
                Button {
                    createDraft.participants.append(.suggested(index: createDraft.participants.count + 1))
                } label: {
                    Label("添加", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("头像")
                            .frame(width: 64, alignment: .center)
                        Text("名称（会自动生成 alias）")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Provider")
                            .frame(width: 160, alignment: .leading)
                        Text("Model")
                            .frame(width: 200, alignment: .leading)
                        Text("角色")
                            .frame(width: 120, alignment: .leading)
                        Text("初始 skill")
                            .frame(width: 180, alignment: .leading)
                        Text("操作")
                            .frame(width: 24, alignment: .center)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 10)

                    ForEach($createDraft.participants) { $participant in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button {
                                    participant.avatarEmoji = MeetingCreationDraft.randomAvatarEmoji(excluding: participant.avatarEmoji)
                                } label: {
                                    Text(participant.avatarEmoji)
                                        .font(.title3)
                                        .frame(width: 44, height: 34)
                                        .background(palette.inputBackground)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help("点击切换头像")

                                TextField("角色名或昵称", text: $participant.displayName)
                                    .textFieldStyle(.roundedBorder)

                                Picker(
                                    "provider",
                                    selection: Binding(
                                        get: { participant.providerOption.rawValue },
                                        set: { selected in
                                            guard let option = MeetingCreationParticipantProvider(rawValue: selected) else {
                                                return
                                            }
                                            participant.updateProvider(option)
                                        }
                                    )
                                ) {
                                    ForEach(MeetingCreationParticipantProvider.allCases) { provider in
                                        Text(provider.displayName).tag(provider.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: 160)
                                .disabled(participant.isSelf)

                                Picker("model", selection: $participant.model) {
                                    ForEach(participant.providerOption.modelOptions, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: 200)
                                .disabled(participant.isSelf)

                                Picker(
                                    "角色",
                                    selection: Binding(
                                        get: { participant.role },
                                        set: { selected in
                                            participant.updateRole(selected)
                                        }
                                    )
                                ) {
                                    ForEach(ParticipantRole.allCases, id: \.self) { role in
                                        Text(role.displayName).tag(role)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: 120)

                                Picker("初始 skill", selection: $participant.skillTemplateID) {
                                    ForEach(createDraft.skillSelectionOptions(for: participant.role)) { option in
                                        Text(option.name).tag(option.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(maxWidth: 180)
                                .disabled(participant.isSelf)

                                if participant.isSelf {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(palette.textSecondary)
                                        .help("默认成员，必须存在")
                                } else {
                                    Button(role: .destructive) {
                                        removeParticipant(participant.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if let resolvedSkill = createDraft.resolveSkillTemplate(
                                skillTemplateID: participant.skillTemplateID,
                                role: participant.role
                            ) {
                                HStack(spacing: 8) {
                                    Text("Skill 预览 · \(resolvedSkill.name)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(palette.textSecondary)
                                    Spacer(minLength: 8)
                                    Button("打开预览") {
                                        let header = "\(participant.displayName) 初始 Skill"
                                        openSkillPreview(template: resolvedSkill, header: header)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(palette.chipBackground)
                                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                }
                                Text(resolvedSkill.content)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(palette.textSecondary)
                                    .lineLimit(3)
                            }
                        }
                        .padding(10)
                        .background(palette.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(palette.border, lineWidth: 1)
                        )
                    }
                }
            }
            .frame(minHeight: 220)

            if let message = createMeetingError ?? createDraft.validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.9))
                    .clipShape(Capsule())
            }

            HStack {
                Spacer()
                Button("取消") {
                    showingCreateMeetingSheet = false
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.chipBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button(isCreatingMeeting ? "创建中..." : "创建并进入") {
                    createMeetingFromDraft()
                }
                .buttonStyle(.plain)
                .disabled(isCreatingMeeting || createDraft.validationMessage != nil)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(palette.accent)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(18)
        .frame(minWidth: 1000, minHeight: 700)
        .background(
            LinearGradient(
                colors: palette.canvasGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .sheet(item: $skillPreviewSelection, onDismiss: {
            skillPreviewSelection = nil
        }) { selection in
            skillPreviewSheet(selection: selection)
        }
    }

    private func openCreateMeetingPanel() {
        createDraft = .defaultValue
        createMeetingError = nil
        skillImportError = nil
        showingCreateMeetingSheet = true
    }

    private func copyMeetingID(_ meetingID: UUID) {
        let meetingIDString = meetingID.uuidString.lowercased()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(meetingIDString, forType: .string)
        store.showActionStatus("已复制会议 ID")
    }

    private func openCreateMeetingPanel(copying meeting: Meeting) {
        createDraft = .copied(from: meeting)
        createMeetingError = nil
        skillImportError = nil
        showingCreateMeetingSheet = true
    }

    private func removeParticipant(_ id: UUID) {
        guard let index = createDraft.participants.firstIndex(where: { $0.id == id }) else {
            return
        }
        guard !createDraft.participants[index].isSelf else {
            return
        }
        createDraft.participants.remove(at: index)
    }

    private func importSkillFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            skillImportError = error.localizedDescription
        case .success(let urls):
            guard !urls.isEmpty else { return }
            var importedCount = 0
            var lastError: String?
            for url in urls {
                do {
                    let started = url.startAccessingSecurityScopedResource()
                    defer {
                        if started {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let name = url.deletingPathExtension().lastPathComponent
                    createDraft.addImportedSkillTemplate(
                        name: name.isEmpty ? url.lastPathComponent : name,
                        content: content,
                        filePath: url.path
                    )
                    importedCount += 1
                } catch {
                    lastError = error.localizedDescription
                }
            }
            if importedCount > 0 {
                skillImportError = nil
            } else if let lastError {
                skillImportError = lastError
            }
        }
    }

    private func openPolicySheet(meeting: Meeting) {
        policyDraft = MeetingPolicyDraft(from: meeting.policy)
        policySaveError = nil
        showingPolicySheet = true
    }

    private func savePolicyDraft() {
        guard policyDraft.validationMessage == nil else { return }
        guard let meeting = store.activeMeeting else { return }

        let meetingID = meeting.id
        let snapshot = policyDraft
        isSavingPolicy = true
        policySaveError = nil
        Task {
            do {
                _ = try await store.updateMeetingPolicy(meetingID: meetingID, policy: snapshot.makePolicy())
                await MainActor.run {
                    isSavingPolicy = false
                    showingPolicySheet = false
                }
            } catch {
                await MainActor.run {
                    isSavingPolicy = false
                    policySaveError = error.localizedDescription
                }
            }
        }
    }

    private func createMeetingFromDraft() {
        guard createDraft.validationMessage == nil else { return }
        isCreatingMeeting = true
        createMeetingError = nil
        let snapshot = createDraft
        Task {
            do {
                _ = try await store.createMeeting(
                    title: snapshot.title,
                    goal: snapshot.goal,
                    participants: snapshot.makeParticipants(),
                    defaultSkill: snapshot.makeMeetingDefaultSkill(),
                    additionalSkills: snapshot.makeAdditionalSkills(),
                    policy: snapshot.makePolicy(),
                    autoStart: snapshot.autoStart
                )
                await MainActor.run {
                    isCreatingMeeting = false
                    showingCreateMeetingSheet = false
                    createDraft = .defaultValue
                }
            } catch {
                await MainActor.run {
                    isCreatingMeeting = false
                    createMeetingError = error.localizedDescription
                }
            }
        }
    }

    private func chatTimeline(meeting: Meeting) -> some View {
        let activeStyle = resolvedBubbleStyle(for: meeting.id)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(meeting.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? meeting.messages[index - 1] : nil
                        let next = index + 1 < meeting.messages.count ? meeting.messages[index + 1] : nil
                        let groupedWithPrevious = shouldGroupMessage(previous: previous, current: message, style: activeStyle)
                        let groupedWithNext = shouldGroupMessage(previous: message, current: next, style: activeStyle)
                        let participant = store.participant(for: message.fromAlias, in: meeting)

                        if shouldShowTimelineMark(previous: previous, current: message) {
                            timelineMark(date: message.createdAt)
                                .padding(.top, index == 0 ? 0 : 8)
                        }

                        ChatBubbleRow(
                            message: message,
                            participant: participant,
                            isFromCurrentUser: message.fromAlias.caseInsensitiveCompare("me") == .orderedSame,
                            groupedWithPrevious: groupedWithPrevious,
                            groupedWithNext: groupedWithNext,
                            isTimestampVisible: messageIDsShowingTimestamp.contains(message.id),
                            onDelete: {
                                messageIDsShowingTimestamp.remove(message.id)
                                store.deleteMessage(meetingID: meeting.id, messageID: message.id)
                            },
                            onToggleTimeVisibility: {
                                toggleMessageTimeVisibility(messageID: message.id)
                            },
                            style: activeStyle,
                            palette: palette
                        )
                        .padding(.top, groupedWithPrevious ? activeStyle.groupedTopSpacing : 12)
                        .id(message.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .animation(.easeInOut(duration: UIMotion.standard), value: meeting.messages.count)
                .animation(.easeInOut(duration: UIMotion.standard), value: activeStyle)
            }
            .background(palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            )
            .onChange(of: meeting.messages.count) { _, _ in
                if let last = meeting.messages.last {
                    withAnimation(.easeOut(duration: UIMotion.standard)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func shouldGroupMessage(previous: MeetingMessage?, current: MeetingMessage?, style: ChatBubbleStyle) -> Bool {
        guard let previous, let current else { return false }
        if previous.fromAlias.caseInsensitiveCompare(current.fromAlias) != .orderedSame {
            return false
        }
        let sameDay = Calendar.current.isDate(previous.createdAt, inSameDayAs: current.createdAt)
        if !sameDay {
            return false
        }
        return current.createdAt.timeIntervalSince(previous.createdAt) < style.groupedTimeWindow
    }

    private func shouldShowTimelineMark(previous: MeetingMessage?, current: MeetingMessage) -> Bool {
        guard let previous else { return true }
        let calendar = Calendar.current
        if !calendar.isDate(previous.createdAt, inSameDayAs: current.createdAt) {
            return true
        }
        return current.createdAt.timeIntervalSince(previous.createdAt) > (15 * 60)
    }

    private func timelineMark(date: Date) -> some View {
        Text(date.formatted(date: .abbreviated, time: .shortened))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(palette.chipBackground)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }

    private func toggleMessageTimeVisibility(messageID: UUID) {
        if messageIDsShowingTimestamp.contains(messageID) {
            messageIDsShowingTimestamp.remove(messageID)
        } else {
            messageIDsShowingTimestamp.insert(messageID)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextEditor(
                    text: Binding(
                        get: { store.draftMessage },
                        set: { store.draftMessage = $0 }
                    )
                )
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 76, maxHeight: 140)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(palette.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )

                Button {
                    withAnimation(.easeInOut(duration: UIMotion.standard)) {
                        showingAttachmentTray.toggle()
                    }
                } label: {
                    Image(systemName: showingAttachmentTray ? "paperclip.circle.fill" : "paperclip.circle")
                        .font(.title3)
                        .foregroundStyle(palette.textPrimary)
                        .padding(6)
                        .background(palette.chipBackground)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("显示或隐藏附件托盘")

                Button("发送") {
                    store.sendDraftMessage()
                }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if showingAttachmentTray {
                HStack(spacing: 10) {
                    TextField(
                        "附件绝对路径（文件或图片）",
                        text: Binding(
                            get: { store.draftAttachmentPath },
                            set: { store.draftAttachmentPath = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(palette.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )

                    Button("附加") {
                        store.attachDraftPath()
                    }
                    .buttonStyle(.plain)
                    .font(.headline)
                    .foregroundStyle(palette.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(palette.chipBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
                }
            }

        }
        .padding(14)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
        .animation(.easeInOut(duration: UIMotion.standard), value: showingAttachmentTray)
    }

    private var globalBubbleStyle: ChatBubbleStyle {
        ChatBubbleStyle(rawValue: bubbleStyleRawValue) ?? .chatty
    }

    private var globalBubbleStyleSelection: Binding<ChatBubbleStyle> {
        Binding(
            get: { globalBubbleStyle },
            set: { bubbleStyleRawValue = $0.rawValue }
        )
    }

    private func resolvedBubbleStyle(for meetingID: UUID) -> ChatBubbleStyle {
        let overrides = meetingBubbleStyleOverrides()
        let key = meetingStyleKey(for: meetingID)
        if let rawValue = overrides[key], let style = ChatBubbleStyle(rawValue: rawValue) {
            return style
        }
        return globalBubbleStyle
    }

    private func meetingBubbleStyleSelection(for meetingID: UUID) -> Binding<String> {
        Binding(
            get: {
                let overrides = meetingBubbleStyleOverrides()
                let key = meetingStyleKey(for: meetingID)
                return overrides[key] ?? "global"
            },
            set: { selected in
                var overrides = meetingBubbleStyleOverrides()
                let key = meetingStyleKey(for: meetingID)
                if selected == "global" {
                    overrides.removeValue(forKey: key)
                } else if ChatBubbleStyle(rawValue: selected) != nil {
                    overrides[key] = selected
                } else {
                    overrides.removeValue(forKey: key)
                }
                persistMeetingBubbleStyleOverrides(overrides)
            }
        )
    }

    private func meetingBubbleStyleOverrides() -> [String: String] {
        guard let data = bubbleStyleMeetingOverridesRawValue.data(using: .utf8) else {
            return [:]
        }
        guard let overrides = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return overrides
    }

    private func persistMeetingBubbleStyleOverrides(_ overrides: [String: String]) {
        if overrides.isEmpty {
            bubbleStyleMeetingOverridesRawValue = "{}"
            return
        }
        guard let data = try? JSONEncoder().encode(overrides),
              let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        bubbleStyleMeetingOverridesRawValue = rawValue
    }

    private func meetingStyleKey(for meetingID: UUID) -> String {
        meetingID.uuidString.lowercased()
    }

    private var palette: UIPalette {
        if colorScheme == .dark {
            return .dark
        }
        return .light
    }
}

private enum BannerTone {
    case success
    case error

    var iconName: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct StatusBanner: View {
    let text: String
    let tone: BannerTone
    let actionTitle: String?
    let action: (() -> Void)?
    let palette: UIPalette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tone.iconName)
                .foregroundStyle(tone == .success ? Color.green : Color.red)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct StateCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String?
    let action: (() -> Void)?
    let palette: UIPalette

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(palette.accent)
            Text(title)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(palette.textPrimary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(palette.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: 440)
        .padding(24)
        .background(palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        )
    }
}

private struct ParticipantLogSelection: Identifiable {
    let meetingID: UUID
    let participantAlias: String

    var id: String {
        "\(meetingID.uuidString.lowercased())::\(participantAlias.lowercased())"
    }
}

private struct SkillPreviewSelection: Identifiable {
    let id = UUID()
    let header: String
    let name: String
    let content: String
    let source: MeetingSkillTemplateDraft.Source
    let filePath: String?
}

private struct MeetingListRow: View {
    let meeting: Meeting
    let unreadCount: Int
    let isActive: Bool

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(meeting.phase == .running ? Color.green : Color.gray)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text("\(meeting.participants.count) people")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.75))
                Text("• \(meeting.phase.rawValue) · \(meetingTimeLabel)")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.65))
            }

            Spacer()

            if unreadCount > 0 {
                Text("\(unreadCount)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            isActive ? Color.white.opacity(0.19) : Color.white.opacity(0.06)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(isActive ? 0.25 : 0.1), lineWidth: 1)
        )
    }

    private var meetingTimeLabel: String {
        let now = Date()
        let age = now.timeIntervalSince(meeting.createdAt)
        if age > 7 * 24 * 60 * 60 {
            return meeting.createdAt.formatted(date: .abbreviated, time: .shortened)
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: meeting.createdAt, relativeTo: now)
    }
}

private struct ChatBubbleRow: View {
    let message: MeetingMessage
    let participant: Participant?
    let isFromCurrentUser: Bool
    let groupedWithPrevious: Bool
    let groupedWithNext: Bool
    let isTimestampVisible: Bool
    let onDelete: () -> Void
    let onToggleTimeVisibility: () -> Void
    let style: ChatBubbleStyle
    let palette: UIPalette

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isFromCurrentUser {
                Spacer(minLength: 60)
            } else {
                avatarSlot
            }

            VStack(alignment: isFromCurrentUser ? .trailing : .leading, spacing: groupedWithPrevious ? 2 : 6) {
                if !groupedWithPrevious {
                    header
                }
                messageBubble
                if isTimestampVisible {
                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(palette.textSecondary)
                }
            }

            if isFromCurrentUser {
                avatarSlot
            } else {
                Spacer(minLength: 60)
            }
        }
    }

    private var messageBubble: some View {
        Text(message.content)
            .font(.body)
            .foregroundStyle(isFromCurrentUser ? Color.white : palette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 560, alignment: isFromCurrentUser ? .trailing : .leading)
            .background(isFromCurrentUser ? palette.accent : palette.messageBubble)
            .clipShape(bubbleShape)
            .overlay(
                bubbleShape
                    .stroke(isFromCurrentUser ? Color.clear : palette.border, lineWidth: 1)
            )
            .contextMenu {
                Button {
                    copyMessageContent()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }

                Button {
                    onToggleTimeVisibility()
                } label: {
                    Label(isTimestampVisible ? "隐藏时间" : "显示时间", systemImage: "clock")
                }
            }
    }

    private var avatarSlot: some View {
        Group {
            if !groupedWithPrevious {
                avatar
            } else {
                Color.clear
                    .frame(width: 34, height: 34)
            }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        let large = style.bubbleLargeCorner
        let small = style.bubbleSmallCorner

        if isFromCurrentUser {
            return UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: large,
                    bottomLeading: large,
                    bottomTrailing: groupedWithNext ? small : large,
                    topTrailing: groupedWithPrevious ? small : large
                ),
                style: .continuous
            )
        }

        return UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: groupedWithPrevious ? small : large,
                bottomLeading: groupedWithNext ? small : large,
                bottomTrailing: large,
                topTrailing: large
            ),
            style: .continuous
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(participant?.displayName ?? message.fromAlias)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            Text("@\(message.fromAlias)")
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
            if let participant {
                Text(participant.model)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.textSecondary)
                ForEach(participant.roles, id: \.self) { role in
                    Text(role.rawValue)
                        .font(.caption2.bold())
                        .foregroundStyle(roleTextColor(for: role))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(roleBackgroundColor(for: role))
                        .clipShape(Capsule())
                }
            }
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(palette.textSecondary)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let emoji = participant?.resolvedAvatarEmoji {
            Text(emoji)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(isFromCurrentUser ? palette.accent.opacity(0.2) : palette.chipBackground)
                )
        } else {
            let initials = participant?.displayName
                .split(separator: " ")
                .prefix(2)
                .compactMap { $0.first }
                .map(String.init)
                .joined() ?? String(message.fromAlias.prefix(2)).uppercased()

            Text(initials.uppercased())
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(isFromCurrentUser ? palette.accent : Color(red: 0.0, green: 0.58, blue: 0.54))
                )
        }
    }

    private func copyMessageContent() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.content, forType: .string)
    }

    private func roleBackgroundColor(for role: ParticipantRole) -> Color {
        switch role {
        case .host:
            return Color.blue.opacity(0.16)
        case .planner:
            return Color.teal.opacity(0.18)
        case .reviewer:
            return Color.orange.opacity(0.20)
        case .judge:
            return Color.red.opacity(0.18)
        case .observer:
            return Color.gray.opacity(0.2)
        }
    }

    private func roleTextColor(for role: ParticipantRole) -> Color {
        switch role {
        case .host:
            return Color.blue
        case .planner:
            return Color.teal
        case .reviewer:
            return Color.orange
        case .judge:
            return Color.red
        case .observer:
            return Color.gray
        }
    }
}

private enum MeetingCreationParticipantProvider: String, CaseIterable, Identifiable {
    case human
    case codex
    case claude
    case kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .human:
            return "human"
        case .codex:
            return "codex"
        case .claude:
            return "claude"
        case .kimi:
            return "kimi"
        }
    }

    var modelOptions: [String] {
        switch self {
        case .human:
            return ["human"]
        case .codex:
            return ["gpt-5.3-codex", "gpt-5"]
        case .claude:
            return ["claude-sonnet"]
        case .kimi:
            return ["kimi-k2"]
        }
    }

    var defaultModel: String {
        modelOptions.first ?? "human"
    }

    static func resolve(from rawProvider: String) -> MeetingCreationParticipantProvider {
        let normalized = rawProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MeetingCreationParticipantProvider(rawValue: normalized) ?? .codex
    }
}

private struct MeetingSkillTemplateDraft: Identifiable, Hashable {
    enum Source: String, Hashable {
        case builtIn
        case imported
    }

    let id: String
    var name: String
    var content: String
    var source: Source
    var filePath: String?

    func makeSkillDocument() -> MeetingSkillDocument {
        let normalizedSource: MeetingSkillSource = {
            switch source {
            case .builtIn:
                return .builtIn
            case .imported:
                return .imported
            }
        }()
        return MeetingSkillDocument(
            name: name,
            content: content,
            source: normalizedSource,
            filePath: filePath
        )
    }
}

private struct SkillSelectionOption: Identifiable, Hashable {
    let id: String
    let name: String
}

private struct MeetingCreationParticipantDraft: Identifiable, Hashable {
    let id: UUID
    var alias: String
    var displayName: String
    var avatarEmoji: String
    var provider: String
    var model: String
    var role: ParticipantRole
    var skillTemplateID: String
    var isSelf: Bool

    init(
        id: UUID = UUID(),
        alias: String,
        displayName: String,
        avatarEmoji: String = "🙂",
        provider: String,
        model: String,
        role: ParticipantRole,
        skillTemplateID: String = MeetingCreationDraft.roleDefaultSkillTemplateID,
        isSelf: Bool = false
    ) {
        self.id = id
        self.alias = alias
        self.displayName = displayName
        self.avatarEmoji = avatarEmoji
        self.provider = provider
        self.model = model
        self.role = role
        self.skillTemplateID = skillTemplateID
        self.isSelf = isSelf
    }

    var providerOption: MeetingCreationParticipantProvider {
        MeetingCreationParticipantProvider.resolve(from: provider)
    }

    mutating func updateProvider(_ option: MeetingCreationParticipantProvider) {
        provider = option.rawValue
        if !option.modelOptions.contains(model) {
            model = option.defaultModel
        }
    }

    mutating func normalizeModelForProvider() {
        let option = providerOption
        if !option.modelOptions.contains(model) {
            model = option.defaultModel
        }
    }

    mutating func updateRole(_ selectedRole: ParticipantRole) {
        let previousRoleName = role.displayName
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        role = selectedRole
        if normalizedDisplayName.isEmpty || normalizedDisplayName.caseInsensitiveCompare(previousRoleName) == .orderedSame {
            displayName = selectedRole.displayName
        }
    }

    static func suggested(index: Int) -> MeetingCreationParticipantDraft {
        MeetingCreationParticipantDraft(
            alias: "agent-\(index)",
            displayName: ParticipantRole.observer.displayName,
            avatarEmoji: MeetingCreationDraft.randomAvatarEmoji(),
            provider: MeetingCreationParticipantProvider.codex.rawValue,
            model: "gpt-5.3-codex",
            role: .observer,
            skillTemplateID: MeetingCreationDraft.roleDefaultSkillTemplateID
        )
    }

    func makeParticipant(initialSkill: MeetingSkillDocument?) -> Participant {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliasFallbackSeed = normalizedDisplayName.isEmpty ? role.displayName : normalizedDisplayName
        let fallbackAlias = MeetingCreationDraft.makeAliasSeed(from: aliasFallbackSeed)
        let manualAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedAliasForAgent: String
        if manualAlias.isEmpty {
            resolvedAliasForAgent = fallbackAlias.isEmpty ? "agent" : fallbackAlias
        } else {
            resolvedAliasForAgent = manualAlias
        }
        let normalizedAlias = isSelf
            ? MeetingCreationDraft.requiredSelfAlias
            : resolvedAliasForAgent
        let normalizedProvider = isSelf
            ? "human"
            : provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = isSelf
            ? "human"
            : model.trimmingCharacters(in: .whitespacesAndNewlines)

        return Participant(
            alias: normalizedAlias,
            displayName: normalizedDisplayName.isEmpty ? role.displayName : normalizedDisplayName,
            avatarEmoji: avatarEmoji.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: normalizedProvider,
            model: normalizedModel,
            roles: [role],
            initialSkill: initialSkill
        )
    }
}

private struct MeetingCreationDraft {
    var title: String
    var goal: String
    var autoStart: Bool
    var speakingMode: MeetingSpeakingMode
    var judgeAutoDecision: Bool
    var maxConcurrentAgents: Int
    var meetingDefaultSkillTemplateID: String
    var selectedAdditionalSkillTemplateIDs: Set<String>
    var importedSkillTemplates: [MeetingSkillTemplateDraft]
    var participants: [MeetingCreationParticipantDraft]

    static let requiredSelfAlias = "me"
    static let roleDefaultSkillTemplateID = "__role_default__"
    static let noSkillTemplateID = "__no_skill__"
    static let avatarEmojiOptions: [String] = [
        "😀", "😎", "🤖", "🧠", "🛠️", "🧩", "🧭", "🔍", "🧪", "⚙️",
        "🚀", "🦊", "🐼", "🐙", "🦉", "🐯", "🦁", "🐬", "🐧", "🦄",
        "🍀", "🔥", "🌊", "🌟", "☁️", "🌈", "🎯", "📌", "📎", "📘",
    ]

    static let builtInMeetingSkillTemplates: [MeetingSkillTemplateDraft] = [
        MeetingSkillTemplateDraft(
            id: "builtin:meeting-core",
            name: "会议默认 Skill（角色职责说明）",
            content: """
            会议目标：
            1) 快速收敛结论，不做无效争论。
            2) 每轮发言只给一条最关键观点。

            角色职责：
            - host：把控节奏、明确问题、推动决策。
            - planner：提出可执行方案与分解计划。
            - reviewer：识别风险、边界条件与回归点。
            - judge：判断是否继续、收敛或终止。
            - observer：补充遗漏信息和客观事实。
            """,
            source: .builtIn,
            filePath: nil
        ),
        MeetingSkillTemplateDraft(
            id: "builtin:meeting-delivery",
            name: "会议默认 Skill（交付导向）",
            content: """
            发言要求：
            - 结论先行，随后给依据。
            - 每条建议要包含“影响范围 + 风险 + 下一步”。
            - 禁止空泛表达与重复观点。
            """,
            source: .builtIn,
            filePath: nil
        ),
    ]

    static let builtInRoleSkillTemplates: [ParticipantRole: MeetingSkillTemplateDraft] = [
        .host: MeetingSkillTemplateDraft(
            id: "builtin:role-host",
            name: "角色 Skill · host",
            content: "你负责主持会议，聚焦议题、控制节奏、推动形成可执行结论。",
            source: .builtIn
        ),
        .planner: MeetingSkillTemplateDraft(
            id: "builtin:role-planner",
            name: "角色 Skill · planner",
            content: "你负责提出计划与方案，给出步骤、依赖、资源估算与落地顺序。",
            source: .builtIn
        ),
        .reviewer: MeetingSkillTemplateDraft(
            id: "builtin:role-reviewer",
            name: "角色 Skill · reviewer",
            content: "你负责评审方案，指出漏洞、边界条件、兼容性和回归风险。",
            source: .builtIn
        ),
        .judge: MeetingSkillTemplateDraft(
            id: "builtin:role-judge",
            name: "角色 Skill · judge",
            content: "你负责给出裁决：continue / converge / terminate，并说明依据。",
            source: .builtIn
        ),
        .observer: MeetingSkillTemplateDraft(
            id: "builtin:role-observer",
            name: "角色 Skill · observer",
            content: "你负责补充客观事实、遗漏点和上下文，避免讨论偏离问题。",
            source: .builtIn
        ),
    ]

    static var requiredSelfParticipant: MeetingCreationParticipantDraft {
        MeetingCreationParticipantDraft(
            alias: requiredSelfAlias,
            displayName: "You",
            avatarEmoji: randomAvatarEmoji(),
            provider: MeetingCreationParticipantProvider.human.rawValue,
            model: MeetingCreationParticipantProvider.human.defaultModel,
            role: .host,
            skillTemplateID: noSkillTemplateID,
            isSelf: true
        )
    }

    static var defaultValue: MeetingCreationDraft {
        MeetingCreationDraft(
            title: "",
            goal: "",
            autoStart: true,
            speakingMode: .judgeGated,
            judgeAutoDecision: true,
            maxConcurrentAgents: 1,
            meetingDefaultSkillTemplateID: builtInMeetingSkillTemplates.first?.id ?? "builtin:meeting-core",
            selectedAdditionalSkillTemplateIDs: [],
            importedSkillTemplates: [],
            participants: [
                requiredSelfParticipant,
                MeetingCreationParticipantDraft(
                    alias: "claude-a",
                    displayName: "planner",
                    avatarEmoji: randomAvatarEmoji(),
                    provider: MeetingCreationParticipantProvider.claude.rawValue,
                    model: "claude-sonnet",
                    role: .planner,
                    skillTemplateID: roleDefaultSkillTemplateID
                ),
                MeetingCreationParticipantDraft(
                    alias: "codex-r1",
                    displayName: "reviewer",
                    avatarEmoji: randomAvatarEmoji(),
                    provider: MeetingCreationParticipantProvider.codex.rawValue,
                    model: "gpt-5.3-codex",
                    role: .reviewer,
                    skillTemplateID: roleDefaultSkillTemplateID
                ),
            ]
        )
    }

    static func copied(from meeting: Meeting) -> MeetingCreationDraft {
        var importedSkillTemplates: [MeetingSkillTemplateDraft] = []

        let copiedDefaultSkillID: String = {
            guard let defaultSkill = meeting.defaultSkill else {
                return builtInMeetingSkillTemplates.first?.id ?? "builtin:meeting-core"
            }
            return mapMeetingSkillTemplateID(
                from: defaultSkill,
                importedTemplates: &importedSkillTemplates,
                prefix: "meeting-default"
            )
        }()

        var copiedAdditionalSkillIDs: Set<String> = []
        for skill in meeting.additionalSkills {
            let skillID = mapMeetingSkillTemplateID(
                from: skill,
                importedTemplates: &importedSkillTemplates,
                prefix: "meeting-extra"
            )
            copiedAdditionalSkillIDs.insert(skillID)
        }

        var copiedParticipants: [MeetingCreationParticipantDraft] = []
        copiedParticipants.reserveCapacity(max(1, meeting.participants.count))
        var hasSelf = false

        for participant in meeting.participants {
            let isSelf = participant.alias.caseInsensitiveCompare(requiredSelfAlias) == .orderedSame
            if isSelf {
                var selfDraft = requiredSelfParticipant
                let copiedName = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !copiedName.isEmpty {
                    selfDraft.displayName = copiedName
                }
                if let copiedAvatar = participant.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !copiedAvatar.isEmpty
                {
                    selfDraft.avatarEmoji = copiedAvatar
                }
                selfDraft.role = participant.primaryRole
                copiedParticipants.append(selfDraft)
                hasSelf = true
                continue
            }

            let role = participant.primaryRole
            let copiedSkillTemplateID: String = {
                guard let initialSkill = participant.initialSkill else {
                    return roleDefaultSkillTemplateID
                }
                if let builtInRoleSkill = builtInRoleSkillTemplates[role],
                   skillContentMatches(templateContent: builtInRoleSkill.content, skillContent: initialSkill.content)
                {
                    return roleDefaultSkillTemplateID
                }
                return mapMeetingSkillTemplateID(
                    from: initialSkill,
                    importedTemplates: &importedSkillTemplates,
                    prefix: "participant-\(participant.alias)"
                )
            }()

            var copiedParticipant = MeetingCreationParticipantDraft(
                alias: participant.alias,
                displayName: participant.displayName,
                avatarEmoji: participant.resolvedAvatarEmoji,
                provider: participant.provider,
                model: participant.model,
                role: role,
                skillTemplateID: copiedSkillTemplateID,
                isSelf: false
            )
            copiedParticipant.normalizeModelForProvider()
            copiedParticipants.append(copiedParticipant)
        }

        if !hasSelf {
            copiedParticipants.insert(requiredSelfParticipant, at: 0)
        }

        return MeetingCreationDraft(
            title: makeCopiedTitle(from: meeting.title),
            goal: meeting.goal,
            autoStart: true,
            speakingMode: meeting.policy.mode,
            judgeAutoDecision: meeting.policy.judgeAutoDecision,
            maxConcurrentAgents: meeting.policy.maxConcurrentAgents,
            meetingDefaultSkillTemplateID: copiedDefaultSkillID,
            selectedAdditionalSkillTemplateIDs: copiedAdditionalSkillIDs,
            importedSkillTemplates: importedSkillTemplates,
            participants: copiedParticipants
        )
    }

    var allSkillTemplates: [MeetingSkillTemplateDraft] {
        Self.builtInMeetingSkillTemplates + importedSkillTemplates
    }

    var selectedMeetingDefaultSkillTemplate: MeetingSkillTemplateDraft? {
        allSkillTemplates.first(where: { $0.id == meetingDefaultSkillTemplateID })
            ?? Self.builtInMeetingSkillTemplates.first
    }

    var validationMessage: String? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedTitle.isEmpty {
            return "请先输入会议标题"
        }

        if participants.count < 3 || participants.count > 6 {
            return "参会人数需在 3 到 6 人之间"
        }
        if maxConcurrentAgents < 1 {
            return "最大并发 Agent 需大于等于 1"
        }
        if !participants.contains(where: \.isSelf) {
            return "默认成员 me 必须存在"
        }

        var hasAgent = false
        for participant in participants {
            let provider = participant.isSelf
                ? "human"
                : participant.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let model = participant.isSelf
                ? "human"
                : participant.model.trimmingCharacters(in: .whitespacesAndNewlines)

            if provider.isEmpty {
                return "provider 不能为空（alias: \(participant.alias)）"
            }
            if model.isEmpty {
                return "model 不能为空（alias: \(participant.alias)）"
            }

            let providerOption = MeetingCreationParticipantProvider.resolve(from: provider)
            if !providerOption.modelOptions.contains(model) {
                return "model 不在可选范围内（alias: \(participant.alias)）"
            }
            if !participant.isSelf, resolveSkillTemplate(skillTemplateID: participant.skillTemplateID, role: participant.role) == nil {
                return "未找到初始 skill（\(participant.displayName)）"
            }
            if providerOption != .human {
                hasAgent = true
            }
        }

        if !hasAgent {
            return "至少需要 1 个 AI Agent"
        }
        if selectedMeetingDefaultSkillTemplate == nil {
            return "默认会议 skill 不能为空"
        }
        return nil
    }

    mutating func addImportedSkillTemplate(name: String, content: String, filePath: String) {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return }

        let id = "imported:\(UUID().uuidString.lowercased())"
        let template = MeetingSkillTemplateDraft(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Skill" : name,
            content: normalizedContent,
            source: .imported,
            filePath: filePath
        )
        importedSkillTemplates.append(template)
        selectedAdditionalSkillTemplateIDs.insert(id)
    }

    mutating func removeImportedSkillTemplate(_ id: String) {
        importedSkillTemplates.removeAll { $0.id == id }
        selectedAdditionalSkillTemplateIDs.remove(id)
        if meetingDefaultSkillTemplateID == id {
            meetingDefaultSkillTemplateID = Self.builtInMeetingSkillTemplates.first?.id ?? "builtin:meeting-core"
        }
        for index in participants.indices where participants[index].skillTemplateID == id {
            participants[index].skillTemplateID = Self.roleDefaultSkillTemplateID
        }
    }

    func skillSelectionOptions(for role: ParticipantRole) -> [SkillSelectionOption] {
        var options: [SkillSelectionOption] = [
            SkillSelectionOption(id: Self.roleDefaultSkillTemplateID, name: "角色默认（\(role.displayName)）"),
        ]
        options.append(contentsOf: allSkillTemplates.map { SkillSelectionOption(id: $0.id, name: $0.name) })
        return options
    }

    func resolveSkillTemplate(skillTemplateID: String, role: ParticipantRole) -> MeetingSkillTemplateDraft? {
        if skillTemplateID == Self.noSkillTemplateID {
            return nil
        }
        if skillTemplateID == Self.roleDefaultSkillTemplateID {
            return Self.builtInRoleSkillTemplates[role]
        }
        return allSkillTemplates.first(where: { $0.id == skillTemplateID })
    }

    func makeParticipants() -> [Participant] {
        var normalizedParticipants = participants
        if !normalizedParticipants.contains(where: \.isSelf) {
            normalizedParticipants.insert(Self.requiredSelfParticipant, at: 0)
        }

        var usedAliases: Set<String> = []
        var mappedParticipants: [Participant] = []
        mappedParticipants.reserveCapacity(normalizedParticipants.count)

        for index in normalizedParticipants.indices {
            if normalizedParticipants[index].isSelf {
                normalizedParticipants[index].alias = Self.requiredSelfAlias
                _ = usedAliases.insert(Self.requiredSelfAlias)
            } else {
                if normalizedParticipants[index].displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    normalizedParticipants[index].displayName = normalizedParticipants[index].role.displayName
                }
                normalizedParticipants[index].normalizeModelForProvider()

                let aliasSeed = Self.makeAliasSeed(
                    from: normalizedParticipants[index].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                let aliasBase = aliasSeed.isEmpty ? "agent" : aliasSeed
                normalizedParticipants[index].alias = Self.makeUniqueAlias(base: aliasBase, usedAliases: &usedAliases)
            }

            let initialSkillTemplate = normalizedParticipants[index].isSelf
                ? nil
                : resolveSkillTemplate(
                    skillTemplateID: normalizedParticipants[index].skillTemplateID,
                    role: normalizedParticipants[index].role
                )
            let participant = normalizedParticipants[index].makeParticipant(
                initialSkill: initialSkillTemplate?.makeSkillDocument()
            )
            mappedParticipants.append(participant)
        }
        return mappedParticipants
    }

    func makeMeetingDefaultSkill() -> MeetingSkillDocument? {
        selectedMeetingDefaultSkillTemplate?.makeSkillDocument()
    }

    func makeAdditionalSkills() -> [MeetingSkillDocument] {
        let selected = allSkillTemplates.filter { selectedAdditionalSkillTemplateIDs.contains($0.id) }
        return selected.map { $0.makeSkillDocument() }
    }

    private static func mapMeetingSkillTemplateID(
        from skill: MeetingSkillDocument,
        importedTemplates: inout [MeetingSkillTemplateDraft],
        prefix: String
    ) -> String {
        if let builtIn = builtInMeetingSkillTemplates.first(where: {
            skillContentMatches(templateContent: $0.content, skillContent: skill.content)
        }) {
            return builtIn.id
        }
        if let existing = importedTemplates.first(where: {
            skillContentMatches(templateContent: $0.content, skillContent: skill.content)
        }) {
            return existing.id
        }

        let seed = makeAliasSeed(from: prefix)
        let templateID = "copied:\(seed.isEmpty ? "skill" : seed)-\(UUID().uuidString.lowercased())"
        let template = MeetingSkillTemplateDraft(
            id: templateID,
            name: skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Imported Skill" : skill.name,
            content: skill.content,
            source: .imported,
            filePath: skill.filePath
        )
        importedTemplates.append(template)
        return templateID
    }

    private static func skillContentMatches(templateContent: String, skillContent: String) -> Bool {
        templateContent.trimmingCharacters(in: .whitespacesAndNewlines)
            == skillContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func randomAvatarEmoji(excluding current: String? = nil) -> String {
        let normalizedCurrent = current?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = avatarEmojiOptions.filter { option in
            guard let normalizedCurrent, !normalizedCurrent.isEmpty else { return true }
            return option != normalizedCurrent
        }
        if let selected = candidates.randomElement() {
            return selected
        }
        return avatarEmojiOptions.first ?? "🙂"
    }

    private static func makeCopiedTitle(from title: String) -> String {
        let marker = " - 副本"
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "新会议" : trimmed

        guard let markerRange = base.range(of: marker, options: .backwards) else {
            return "\(base)\(marker)"
        }

        let trailing = base[markerRange.upperBound...]
        if trailing.isEmpty {
            return "\(base) 2"
        }

        guard trailing.first == " " else {
            return "\(base)\(marker)"
        }

        let numberText = trailing.dropFirst()
        guard !numberText.isEmpty,
              numberText.allSatisfy(\.isNumber),
              let current = Int(numberText),
              current >= 2 else
        {
            return "\(base)\(marker)"
        }

        let prefix = base[..<markerRange.lowerBound]
        return "\(prefix)\(marker) \(current + 1)"
    }

    static func makeAliasSeed(from rawValue: String) -> String {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty {
            return ""
        }

        let replaced = normalized.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func makeUniqueAlias(base: String, usedAliases: inout Set<String>) -> String {
        if !usedAliases.contains(base) {
            _ = usedAliases.insert(base)
            return base
        }

        var suffix = 2
        while true {
            let candidate = "\(base)-\(suffix)"
            if !usedAliases.contains(candidate) {
                _ = usedAliases.insert(candidate)
                return candidate
            }
            suffix += 1
        }
    }

    func makePolicy() -> MeetingPolicy {
        MeetingPolicy(
            mode: speakingMode,
            maxConcurrentAgents: maxConcurrentAgents,
            judgeAutoDecision: judgeAutoDecision
        )
    }
}

private struct MeetingPolicyDraft {
    var speakingMode: MeetingSpeakingMode
    var judgeAutoDecision: Bool
    var maxConcurrentAgents: Int

    static let defaultValue = MeetingPolicyDraft(
        speakingMode: .roundRobin,
        judgeAutoDecision: true,
        maxConcurrentAgents: 1
    )

    init(
        speakingMode: MeetingSpeakingMode,
        judgeAutoDecision: Bool,
        maxConcurrentAgents: Int
    ) {
        self.speakingMode = speakingMode
        self.judgeAutoDecision = judgeAutoDecision
        self.maxConcurrentAgents = maxConcurrentAgents
    }

    init(from policy: MeetingPolicy) {
        self.init(
            speakingMode: policy.mode,
            judgeAutoDecision: policy.judgeAutoDecision,
            maxConcurrentAgents: policy.maxConcurrentAgents
        )
    }

    var validationMessage: String? {
        if maxConcurrentAgents < 1 {
            return "最大并发 Agent 需大于等于 1"
        }
        return nil
    }

    func makePolicy() -> MeetingPolicy {
        MeetingPolicy(
            mode: speakingMode,
            maxConcurrentAgents: maxConcurrentAgents,
            judgeAutoDecision: judgeAutoDecision
        )
    }
}

private extension ParticipantRole {
    var displayName: String {
        switch self {
        case .host:
            return "host"
        case .planner:
            return "planner"
        case .reviewer:
            return "reviewer"
        case .judge:
            return "judge"
        case .observer:
            return "observer"
        }
    }

    var defaultAvatarEmoji: String {
        switch self {
        case .host:
            return "🎙️"
        case .planner:
            return "🧭"
        case .reviewer:
            return "🔍"
        case .judge:
            return "⚖️"
        case .observer:
            return "👀"
        }
    }
}

private extension Participant {
    var resolvedAvatarEmoji: String {
        if let avatarEmoji {
            let normalized = avatarEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return primaryRole.defaultAvatarEmoji
    }
}

private extension MeetingSpeakingMode {
    var displayName: String {
        switch self {
        case .roundRobin:
            return "轮询"
        case .judgeGated:
            return "裁判闸门"
        case .free:
            return "自由"
        }
    }
}

private extension MeetingTerminationReason {
    var displayName: String {
        switch self {
        case .manualStop:
            return "手动停止"
        case .judgeTerminated:
            return "裁判终止"
        case .appShutdown:
            return "应用关闭"
        case .cliStopped:
            return "CLI 停止"
        }
    }
}

private extension MeetingJudgeDecision {
    var displayName: String {
        switch self {
        case .continue:
            return "继续讨论"
        case .converge:
            return "已收敛"
        case .terminate:
            return "终止会议"
        }
    }
}

private extension MeetingSkillTemplateDraft.Source {
    var displayName: String {
        switch self {
        case .builtIn:
            return "内置模板"
        case .imported:
            return "导入文件"
        }
    }
}

private extension String {
    func truncatedForLogPreview(limit: Int) -> String {
        guard limit > 0, count > limit else { return self }
        let endIndex = index(startIndex, offsetBy: limit)
        return String(self[..<endIndex]) + "\n\n...[truncated]"
    }
}

private struct UIPalette {
    let sidebarGradient: [Color]
    let canvasGradient: [Color]
    let panel: Color
    let inputBackground: Color
    let chipBackground: Color
    let messageBubble: Color
    let accent: Color
    let border: Color
    let textPrimary: Color
    let textSecondary: Color

    static let light = UIPalette(
        sidebarGradient: [Color(red: 0.17, green: 0.20, blue: 0.28), Color(red: 0.11, green: 0.15, blue: 0.22)],
        canvasGradient: [Color(red: 0.98, green: 0.96, blue: 0.95), Color(red: 0.94, green: 0.97, blue: 1.0)],
        panel: Color.white.opacity(0.9),
        inputBackground: Color.white.opacity(0.96),
        chipBackground: Color(red: 0.27, green: 0.20, blue: 0.16).opacity(0.08),
        messageBubble: Color.white.opacity(0.94),
        accent: Color(red: 0.22, green: 0.60, blue: 0.73),
        border: Color(red: 0.27, green: 0.20, blue: 0.16).opacity(0.13),
        textPrimary: Color(red: 0.16, green: 0.17, blue: 0.19),
        textSecondary: Color(red: 0.40, green: 0.41, blue: 0.45)
    )

    static let dark = UIPalette(
        sidebarGradient: [Color(red: 0.08, green: 0.09, blue: 0.14), Color(red: 0.10, green: 0.12, blue: 0.18)],
        canvasGradient: [Color(red: 0.10, green: 0.11, blue: 0.14), Color(red: 0.12, green: 0.13, blue: 0.18)],
        panel: Color.white.opacity(0.07),
        inputBackground: Color.white.opacity(0.09),
        chipBackground: Color.white.opacity(0.11),
        messageBubble: Color.white.opacity(0.09),
        accent: Color(red: 0.27, green: 0.69, blue: 0.83),
        border: Color.white.opacity(0.11),
        textPrimary: Color.white.opacity(0.95),
        textSecondary: Color.white.opacity(0.66)
    )
}
