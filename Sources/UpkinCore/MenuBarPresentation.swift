import Foundation

public enum ConversationEventKind: String, Sendable {
    case completed, waiting

    public var phase: AgentTaskPhase { self == .waiting ? .waiting : .completed }
    public var emotion: GrokBallEmotion { self == .waiting ? .waiting : .completed }
}

public struct ConversationEvent: Equatable, Sendable {
    public let conversation: Conversation
    public let kind: ConversationEventKind
    public var notificationID: String { self.conversation.id + "." + self.kind.rawValue }

    public init(conversation: Conversation, kind: ConversationEventKind) {
        self.conversation = conversation
        self.kind = kind
    }

    public func isValid(in conversations: [Conversation]) -> Bool {
        conversations.contains {
            $0.id == self.conversation.id && !$0.isSubagent && !$0.isStale
                && $0.phase == self.kind.phase && $0.turnStartedAt == self.conversation.turnStartedAt
        }
    }
}

public struct ConversationPendingEvents: Sendable {
    public private(set) var waiting: ConversationEvent?
    public private(set) var completed: ConversationEvent?

    public init() {}

    public mutating func receive(_ event: ConversationEvent) {
        switch event.kind {
        case .waiting:
            if event.conversation.updatedAt >= (self.waiting?.conversation.updatedAt ?? -.infinity) { self.waiting = event }
        case .completed:
            if event.conversation.updatedAt >= (self.completed?.conversation.updatedAt ?? -.infinity) { self.completed = event }
        }
    }

    public func next(in conversations: [Conversation]) -> ConversationEvent? {
        if let waiting, waiting.isValid(in: conversations) { return waiting }
        return self.completed.flatMap { $0.isValid(in: conversations) ? $0 : nil }
    }
}

public struct ConversationEventTracker: Sendable {
    public private(set) var conversations: [Conversation] = []
    public private(set) var exitedWaiting: [String] = []
    // Waiting may re-arm only after the task runs again, not after an error/idle detour.
    private var waitingSeen: Set<String> = []
    private var observingSince: TimeInterval?
    private var completedThrough: [String: TimeInterval] = [:]

    public init() {}

    public mutating func update(_ incoming: [Conversation], now: Date = Date()) -> [ConversationEvent] {
        let observingSince = self.observingSince
        self.observingSince = observingSince ?? now.timeIntervalSince1970
        let previous = Dictionary(self.conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.conversations = incoming.map { item in
            var item = item
            let old = previous[item.id]
            if item.phase.isRunning && !item.isStale {
                if let old, !old.phase.isRunning || old.isStale {
                    if item.turnStartedAt == nil || item.turnStartedAt! <= (old.turnStartedAt ?? 0) {
                        item.turnStartedAt = item.updatedAt
                    }
                } else if item.turnStartedAt == nil {
                    item.turnStartedAt = old?.turnStartedAt ?? item.updatedAt
                }
            }
            if let prior = old?.turnStartedAt {
                item.turnStartedAt = max(item.turnStartedAt ?? prior, prior)
            }
            return item
        }
        let byID = Dictionary(self.conversations.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.exitedWaiting = previous.values.filter {
            !$0.isSubagent && !$0.isStale && $0.phase == .waiting
                && (byID[$0.id]?.phase != .waiting || byID[$0.id]?.isStale == true || byID[$0.id]?.isSubagent == true)
        }.map(\.id)
        self.waitingSeen.formIntersection(byID.keys)
        var events: [ConversationEvent] = []
        for item in self.conversations where !item.isSubagent && !item.isStale {
            if item.phase.isRunning { self.waitingSeen.remove(item.id) }
            let old = previous[item.id]
            if item.phase == .waiting {
                if let old, !old.isSubagent, !old.isStale, old.phase != .waiting, !self.waitingSeen.contains(item.id) {
                    events.append(ConversationEvent(conversation: item, kind: .waiting))
                }
                self.waitingSeen.insert(item.id)
            } else if item.phase == .completed,
                      (-60...120).contains(now.timeIntervalSince1970 - item.updatedAt) {
                let observedRunning = old.map { !$0.isSubagent && !$0.isStale
                    && ($0.phase.isRunning || $0.phase == .waiting) && item.updatedAt > $0.updatedAt } ?? false
                // FSEvents can merge a whole short turn into one completed snapshot.
                let freshTurn = item.turnStartedAt.map { start in
                    guard let observingSince, start <= item.updatedAt else { return false }
                    return start > (old?.updatedAt ?? self.completedThrough[item.id] ?? observingSince)
                        && old?.isSubagent != true
                } ?? false
                if observedRunning || freshTurn { events.append(ConversationEvent(conversation: item, kind: .completed)) }
            }
            if item.phase == .completed {
                self.completedThrough[item.id] = max(self.completedThrough[item.id] ?? 0, item.updatedAt)
            }
        }
        return events.sorted {
            $0.conversation.updatedAt == $1.conversation.updatedAt
                ? $0.notificationID < $1.notificationID : $0.conversation.updatedAt < $1.conversation.updatedAt
        }
    }
}

public struct MenuBarPresentation: Sendable {
    public private(set) var tracker = ConversationEventTracker()
    public private(set) var playing: ConversationEvent?
    public private(set) var pending = ConversationPendingEvents()
    public private(set) var provider: CodingAgent?

    public init() {}

    public static func focus(in conversations: [Conversation]) -> Conversation? {
        conversations.filter { !$0.isSubagent && !$0.isStale && $0.phase.isRunning }.max {
            let left = $0.turnStartedAt ?? 0, right = $1.turnStartedAt ?? 0
            return left == right ? $0.id < $1.id : left < right
        }
    }

    public static func hasWaiting(in conversations: [Conversation]) -> Bool {
        conversations.contains { !$0.isSubagent && !$0.isStale && $0.phase == .waiting }
    }

    public var hasWaiting: Bool { Self.hasWaiting(in: self.tracker.conversations) }
    public var displayedConversation: Conversation? {
        self.playing?.conversation ?? Self.focus(in: self.tracker.conversations)
    }

    public var emotion: GrokBallEmotion {
        self.playing?.kind.emotion ?? Self.focus(in: self.tracker.conversations)?.emotion ?? .idle
    }

    @discardableResult
    public mutating func update(_ conversations: [Conversation], now: Date = Date()) -> [ConversationEvent] {
        let events = self.tracker.update(conversations, now: now)
        for event in events {
            if self.playing == nil { self.playing = event }
            else { self.pending.receive(event) }
        }
        self.selectProvider()
        return events
    }

    public mutating func finishPlayback() {
        self.playing = self.pending.next(in: self.tracker.conversations)
        self.pending = ConversationPendingEvents()
        self.selectProvider()
    }

    private mutating func selectProvider() {
        if let playing { self.provider = playing.conversation.provider }
        else if let focus = Self.focus(in: self.tracker.conversations) { self.provider = focus.provider }
    }
}
