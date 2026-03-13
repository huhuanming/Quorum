import AVFAudio
import Foundation
import Observation
import QuorumCore

@MainActor
@Observable
final class MeetingSpeechCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    struct VoiceOption: Identifiable, Hashable {
        let id: String
        let name: String
        let language: String
        let displayLanguage: String

        var displayLabel: String {
            "\(name) · \(displayLanguage)"
        }
    }

    static let automaticVoiceSelectionToken = "__automatic__"
    static let shared = MeetingSpeechCoordinator()

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var queuedItems: [SpeechItem] = []
    @ObservationIgnored private var queuedItemIDs: Set<String> = []
    @ObservationIgnored private var primedMeetingIDs: Set<UUID> = []
    @ObservationIgnored private var seenMessageIDsByMeeting: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var currentItemID: String?

    private(set) var availableVoices: [VoiceOption] = []
    private(set) var isSpeaking = false
    private(set) var activeMeetingID: UUID?

    private override init() {
        super.init()
        synthesizer.delegate = self
        availableVoices = Self.loadAvailableVoices()
    }

    func setActiveMeeting(_ meetingID: UUID?) {
        guard activeMeetingID != meetingID else { return }
        activeMeetingID = meetingID
        stopSpeaking()
        if let meetingID {
            primedMeetingIDs.insert(meetingID)
        }
    }

    func applySnapshot(
        meeting: Meeting,
        enabled: Bool,
        voiceIdentifierByAlias: [String: String]
    ) {
        guard activeMeetingID == meeting.id else { return }

        let currentMessageIDs = Set(meeting.messages.map(\.id))
        if primedMeetingIDs.remove(meeting.id) != nil || seenMessageIDsByMeeting[meeting.id] == nil {
            seenMessageIDsByMeeting[meeting.id] = currentMessageIDs
            return
        }

        let seenMessageIDs = seenMessageIDsByMeeting[meeting.id, default: []]
        let newMessages = meeting.messages.filter { !seenMessageIDs.contains($0.id) }
        seenMessageIDsByMeeting[meeting.id] = seenMessageIDs.union(currentMessageIDs)

        guard enabled else { return }

        let automaticParticipants = Dictionary(
            uniqueKeysWithValues: meeting.participants.map { ($0.alias.lowercased(), $0) }
        )

        for message in newMessages {
            guard let participant = automaticParticipants[message.fromAlias.lowercased()] else {
                continue
            }
            guard participant.provider.caseInsensitiveCompare("human") != .orderedSame else {
                continue
            }

            let explicitVoiceIdentifier = voiceIdentifierByAlias[participant.alias.lowercased()]
            enqueue(
                participant: participant,
                voiceIdentifier: explicitVoiceIdentifier,
                message: message
            )
        }
    }

    func previewVoice(participant: Participant, explicitVoiceIdentifier: String?) {
        stopSpeaking()
        enqueuePreview(participant: participant, voiceIdentifier: explicitVoiceIdentifier)
    }

    func stopSpeaking() {
        queuedItems.removeAll()
        queuedItemIDs.removeAll()
        currentItemID = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.currentItemID = nil
            self.isSpeaking = false
            self.startNextIfPossible()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.currentItemID = nil
            self.isSpeaking = false
            self.startNextIfPossible()
        }
    }

    private func enqueue(
        participant: Participant,
        voiceIdentifier: String?,
        message: MeetingMessage
    ) {
        let text = Self.makeSpeechText(from: message.content, speakerName: participant.displayName)
        guard !text.isEmpty else { return }
        let itemID = "message:\(message.id.uuidString.lowercased())"
        guard canEnqueueItem(withID: itemID) else { return }

        queuedItems.append(
            SpeechItem(
                id: itemID,
                text: text,
                voiceIdentifier: resolvedVoiceIdentifier(
                    for: participant,
                    explicitVoiceIdentifier: voiceIdentifier
                )
            )
        )
        startNextIfPossible()
    }

    private func enqueuePreview(participant: Participant, voiceIdentifier: String?) {
        let previewText = "大家好，我是\(participant.displayName)。现在开始继续讨论。"
        let itemID = "preview:\(participant.alias.lowercased())"
        guard canEnqueueItem(withID: itemID) else { return }
        queuedItems.append(
            SpeechItem(
                id: itemID,
                text: previewText,
                voiceIdentifier: resolvedVoiceIdentifier(
                    for: participant,
                    explicitVoiceIdentifier: voiceIdentifier
                )
            )
        )
        startNextIfPossible()
    }

    private func startNextIfPossible() {
        guard !isSpeaking, !queuedItems.isEmpty else { return }
        let next = queuedItems.removeFirst()
        queuedItemIDs.remove(next.id)
        currentItemID = next.id
        let utterance = AVSpeechUtterance(string: next.text)
        utterance.rate = 0.49
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.12

        if let voiceIdentifier = next.voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        {
            utterance.voice = voice
        }

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func canEnqueueItem(withID itemID: String) -> Bool {
        if currentItemID == itemID || queuedItemIDs.contains(itemID) {
            return false
        }
        queuedItemIDs.insert(itemID)
        return true
    }

    private func resolvedVoiceIdentifier(
        for participant: Participant,
        explicitVoiceIdentifier: String?
    ) -> String? {
        if let explicitVoiceIdentifier,
           explicitVoiceIdentifier != Self.automaticVoiceSelectionToken,
           AVSpeechSynthesisVoice(identifier: explicitVoiceIdentifier) != nil
        {
            return explicitVoiceIdentifier
        }

        let voices = AVSpeechSynthesisVoice.speechVoices().filter(Self.isPreferredVoice)
        let fallback = voices.first?.identifier
        let preferredNames = Self.preferredVoiceNames(for: participant.primaryRole)

        for languagePrefix in Self.preferredLanguagePrefixes {
            for preferredName in preferredNames {
                if let matchedVoice = voices.first(where: {
                    $0.language.hasPrefix(languagePrefix)
                        && $0.name.caseInsensitiveCompare(preferredName) == .orderedSame
                }) {
                    return matchedVoice.identifier
                }
            }
        }

        if let chineseVoice = voices.first(where: { $0.language.hasPrefix("zh") }) {
            return chineseVoice.identifier
        }

        return fallback
    }

    private static func loadAvailableVoices() -> [VoiceOption] {
        let locale = Locale.current
        return AVSpeechSynthesisVoice.speechVoices()
            .filter(isPreferredVoice)
            .map { voice in
                let displayLanguage = locale.localizedString(forIdentifier: voice.language) ?? voice.language
                return VoiceOption(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    displayLanguage: displayLanguage
                )
            }
            .sorted { lhs, rhs in
                let lhsRank = languageRank(for: lhs.language)
                let rhsRank = languageRank(for: rhs.language)
                if lhsRank == rhsRank {
                    if lhs.language == rhs.language {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.language.localizedCaseInsensitiveCompare(rhs.language) == .orderedAscending
                }
                return lhsRank < rhsRank
            }
    }

    private static func isPreferredVoice(_ voice: AVSpeechSynthesisVoice) -> Bool {
        voice.language.hasPrefix("zh") || voice.language.hasPrefix("en")
    }

    private static func languageRank(for language: String) -> Int {
        if language.hasPrefix("zh-CN") { return 0 }
        if language.hasPrefix("zh-TW") { return 1 }
        if language.hasPrefix("en-US") { return 2 }
        if language.hasPrefix("en-GB") { return 3 }
        if language.hasPrefix("zh") { return 4 }
        if language.hasPrefix("en") { return 5 }
        return 6
    }

    private static func preferredVoiceNames(for role: ParticipantRole) -> [String] {
        switch role {
        case .host:
            return ["Shelley", "Tingting", "Sandy", "Daniel"]
        case .planner:
            return ["Tingting", "Sandy", "Reed", "Flo"]
        case .reviewer:
            return ["Rocko", "Reed", "Eddy", "Flo"]
        case .judge:
            return ["Grandpa", "Grandma", "Shelley", "Fred"]
        case .observer:
            return ["Flo", "Eddy", "Sandy", "Junior"]
        }
    }

    private static func makeSpeechText(from rawText: String, speakerName: String) -> String {
        var text = rawText
        text = text.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " 代码片段略。 ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"https?://\S+"#,
            with: " 链接 ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "\n", with: "。")
        text = text.replacingOccurrences(of: #"[-*#]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return "\(speakerName) 说。\(text)"
    }

    private static let preferredLanguagePrefixes = ["zh-CN", "zh-TW", "en-US", "en-GB", "zh", "en"]
}

private struct SpeechItem {
    let id: String
    let text: String
    let voiceIdentifier: String?
}
