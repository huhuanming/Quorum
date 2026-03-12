import SwiftUI
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
                        ForEach(store.meetings, id: \.id) { meeting in
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
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(palette.chipBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

            TextField("会议目标（可选）", text: $createDraft.goal)
                .textFieldStyle(.roundedBorder)

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
                    ForEach($createDraft.participants) { $participant in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                TextField("alias", text: $participant.alias)
                                    .textFieldStyle(.roundedBorder)
                                TextField("显示名", text: $participant.displayName)
                                    .textFieldStyle(.roundedBorder)
                                TextField("provider", text: $participant.provider)
                                    .textFieldStyle(.roundedBorder)
                                TextField("model", text: $participant.model)
                                    .textFieldStyle(.roundedBorder)
                                Button(role: .destructive) {
                                    removeParticipant(participant.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                            }

                            HStack(spacing: 6) {
                                ForEach(ParticipantRole.allCases, id: \.self) { role in
                                    Toggle(
                                        role.rawValue,
                                        isOn: Binding(
                                            get: { participant.roles.contains(role) },
                                            set: { enabled in
                                                if enabled {
                                                    participant.roles.insert(role)
                                                } else {
                                                    participant.roles.remove(role)
                                                }
                                            }
                                        )
                                    )
                                    .toggleStyle(.button)
                                    .font(.caption)
                                }
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
        .frame(minWidth: 920, minHeight: 560)
        .background(
            LinearGradient(
                colors: palette.canvasGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func openCreateMeetingPanel() {
        createDraft = .defaultValue
        createMeetingError = nil
        showingCreateMeetingSheet = true
    }

    private func removeParticipant(_ id: UUID) {
        createDraft.participants.removeAll { $0.id == id }
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

    private var composer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                TextField(
                    "输入消息...",
                    text: Binding(
                        get: { store.draftMessage },
                        set: { store.draftMessage = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(palette.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(palette.border, lineWidth: 1)
                )
                .onSubmit {
                    store.sendDraftMessage()
                }

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
                Text("• \(meeting.phase.rawValue)")
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
}

private struct ChatBubbleRow: View {
    let message: MeetingMessage
    let participant: Participant?
    let isFromCurrentUser: Bool
    let groupedWithPrevious: Bool
    let groupedWithNext: Bool
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
            }

            if isFromCurrentUser {
                avatarSlot
            } else {
                Spacer(minLength: 60)
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

    private var avatar: some View {
        let initials = participant?.displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
            .map(String.init)
            .joined() ?? String(message.fromAlias.prefix(2)).uppercased()

        return Text(initials.uppercased())
            .font(.caption.bold())
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(isFromCurrentUser ? palette.accent : Color(red: 0.0, green: 0.58, blue: 0.54))
            )
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

private struct MeetingCreationParticipantDraft: Identifiable, Hashable {
    let id: UUID
    var alias: String
    var displayName: String
    var provider: String
    var model: String
    var roles: Set<ParticipantRole>

    init(
        id: UUID = UUID(),
        alias: String,
        displayName: String,
        provider: String,
        model: String,
        roles: Set<ParticipantRole>
    ) {
        self.id = id
        self.alias = alias
        self.displayName = displayName
        self.provider = provider
        self.model = model
        self.roles = roles
    }

    static func suggested(index: Int) -> MeetingCreationParticipantDraft {
        MeetingCreationParticipantDraft(
            alias: "agent-\(index)",
            displayName: "Agent \(index)",
            provider: "codex",
            model: "gpt-5",
            roles: [.observer]
        )
    }

    func makeParticipant() -> Participant {
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return Participant(
            alias: normalizedAlias,
            displayName: normalizedDisplayName.isEmpty ? normalizedAlias : normalizedDisplayName,
            provider: provider.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            roles: Array(roles)
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
    var participants: [MeetingCreationParticipantDraft]

    static let defaultValue = MeetingCreationDraft(
        title: "",
        goal: "",
        autoStart: true,
        speakingMode: .judgeGated,
        judgeAutoDecision: true,
        maxConcurrentAgents: 1,
        participants: [
            MeetingCreationParticipantDraft(
                alias: "me",
                displayName: "You",
                provider: "human",
                model: "human",
                roles: [.host, .judge]
            ),
            MeetingCreationParticipantDraft(
                alias: "claude-a",
                displayName: "Claude A",
                provider: "claude",
                model: "claude-sonnet",
                roles: [.planner]
            ),
            MeetingCreationParticipantDraft(
                alias: "codex-r1",
                displayName: "Codex R1",
                provider: "codex",
                model: "gpt-5",
                roles: [.reviewer]
            ),
        ]
    )

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

        var seenAliases = Set<String>()
        for participant in participants {
            let alias = participant.alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if alias.isEmpty {
                return "alias 不能为空"
            }
            if !seenAliases.insert(alias).inserted {
                return "alias 不能重复：\(participant.alias)"
            }

            let provider = participant.provider.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = participant.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if provider.isEmpty {
                return "provider 不能为空（alias: \(participant.alias)）"
            }
            if model.isEmpty {
                return "model 不能为空（alias: \(participant.alias)）"
            }
        }
        return nil
    }

    func makeParticipants() -> [Participant] {
        participants.map { $0.makeParticipant() }
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
