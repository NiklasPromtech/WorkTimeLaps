import Foundation

/// Something someone is waiting on — a reply, a decision or a deliverable —
/// picked up from a work conversation on screen. The morning brief keeps
/// the list current; the user can mark an item done.
///
/// Stored in `<data folder>/_journal/follow-ups.json`.
struct FollowUp: Codable, Sendable, Identifiable, Hashable {
    let id: String
    var with: String
    var request: String
    /// "them": the user is waiting on them. "me": the user owes it.
    var owner: String
    /// Work day it was first seen.
    var since: String
    var status: String
    /// Suggested next step, or how it was resolved.
    var note: String?
    /// Set when the user marked it done; the brief never reopens it.
    var closedByUser: Bool?
    var updatedAt: Date

    var isOpen: Bool { status == "open" }
    var isWaitingOnThem: Bool { owner == "them" }
}

/// One follow-up as the morning brief returns it: an existing id, or "new".
struct FollowUpUpdate: Codable, Sendable {
    let id: String
    let with: String
    let request: String
    let owner: String
    let since: String
    let status: String
    let note: String
}

enum FollowUpStore {

    static var fileURL: URL {
        Journal.folder.appendingPathComponent("follow-ups.json")
    }

    static func loadAll() -> [FollowUp] {
        if case .value(let lossy) = JSONFile.read(LossyArray<FollowUp>.self, from: fileURL) {
            return lossy.elements
        }
        return []
    }

    static var open: [FollowUp] { loadAll().filter(\.isOpen) }

    /// Closed by the user in the last 30 days. The brief is told not to add
    /// these again.
    static func recentlyClosedByUser(now: Date = Date()) -> [FollowUp] {
        loadAll().filter { $0.closedByUser == true && now.timeIntervalSince($0.updatedAt) < 30 * 86_400 }
    }

    /// Marks an item done (or open again, to undo).
    static func setDone(id: String, _ done: Bool, now: Date = Date()) {
        var items = loadAll()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = done ? "resolved" : "open"
        items[idx].closedByUser = done ? true : nil
        items[idx].updatedAt = now
        save(items)
    }

    /// Applies the list the morning brief returned:
    /// - existing ids are updated, and "new" items are added;
    /// - anything the user closed stays closed, and isn't added again;
    /// - a "new" item matching an existing one is merged into it;
    /// - items the brief didn't mention are kept as they are;
    /// - resolved items older than 30 days are dropped.
    @discardableResult
    static func apply(_ updates: [FollowUpUpdate], now: Date = Date()) -> [FollowUp] {
        var items = loadAll()

        for update in updates {
            let owner = update.owner == "me" ? "me" : "them"
            let status = update.status == "resolved" ? "resolved" : "open"
            let note = update.note.trimmingCharacters(in: .whitespacesAndNewlines)

            var idx = items.firstIndex(where: { $0.id == update.id })
            if idx == nil {
                idx = items.firstIndex(where: { isSame($0, with: update.with, request: update.request) })
            }

            if let idx {
                guard items[idx].closedByUser != true else { continue }
                items[idx].with = update.with
                items[idx].request = update.request
                items[idx].owner = owner
                items[idx].status = status
                items[idx].note = note.isEmpty ? nil : note
                items[idx].updatedAt = now
            } else if status == "open" {
                let request = update.request.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !request.isEmpty else { continue }
                items.append(FollowUp(
                    id: UUID().uuidString,
                    with: update.with,
                    request: request,
                    owner: owner,
                    since: WorkDay.isKey(update.since) ? update.since : WorkDay.key(for: now),
                    status: "open",
                    note: note.isEmpty ? nil : note,
                    closedByUser: nil,
                    updatedAt: now
                ))
            }
        }

        items.removeAll { !$0.isOpen && now.timeIntervalSince($0.updatedAt) > 30 * 86_400 }
        save(items)
        return items
    }

    /// Same person and essentially the same request.
    static func isSame(_ item: FollowUp, with: String, request: String) -> Bool {
        guard RecognitionStore.normalizedQuote(item.with) == RecognitionStore.normalizedQuote(with) else { return false }
        let a = Set(RecognitionStore.normalizedQuote(item.request).split(separator: " "))
        let b = Set(RecognitionStore.normalizedQuote(request).split(separator: " "))
        let union = a.union(b).count
        return union > 0 && Double(a.intersection(b).count) / Double(union) >= 0.6
    }

    private static func save(_ items: [FollowUp]) {
        do {
            try JSONFile.write(items.sorted { $0.since < $1.since }, to: fileURL)
        } catch {
            NSLog("WorkTimeLaps: couldn't save follow-ups: \(error.localizedDescription)")
        }
        DiaryStore.postUpdate()
    }
}
