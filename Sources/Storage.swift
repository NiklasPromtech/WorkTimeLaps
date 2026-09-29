import Foundation

/// Small helpers for the JSON files under the data folder.
///
/// The important rule: a file that exists but can't be decoded is never
/// silently treated as empty and overwritten. It's moved aside first, so a
/// schema change, a manual edit gone wrong, or an older build can't wipe
/// the long-term history (`recognitions.json`, day logs, diaries).
enum JSONFile {

    enum ReadResult<T> {
        case missing
        case value(T)
        case unreadable(Error)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONFile.decoder) -> ReadResult<T> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                return .unreadable(error)
            }
            return .missing
        }
        do {
            return .value(try decoder.decode(T.self, from: data))
        } catch {
            return .unreadable(error)
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONFile.prettyEncoder) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    /// Renames an unreadable file to `<name>.unreadable-<timestamp>.json`
    /// next to the original and returns the new location.
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(stem).unreadable-\(f.string(from: Date())).json")
        do {
            try FileManager.default.moveItem(at: url, to: target)
            NSLog("WorkTimeLaps: moved unreadable \(url.lastPathComponent) aside to \(target.lastPathComponent)")
            return target
        } catch {
            NSLog("WorkTimeLaps: couldn't move unreadable \(url.lastPathComponent) aside: \(error.localizedDescription)")
            return nil
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Pretty, key-sorted output for files people might open by hand.
    static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Compact output for large files that are rewritten often (session
    /// sidecars). Still valid JSON — pipe through `jq` to read it.
    static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

/// Decodes an array element by element, dropping entries that fail to
/// decode instead of failing the whole file.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Skip the undecodable element so the loop advances.
                _ = try? container.decode(AnyDecodable.self)
                dropped += 1
            }
        }
        self.elements = elements
        self.droppedCount = dropped
    }

    private struct AnyDecodable: Decodable {
        init(from decoder: Decoder) throws {}
    }
}
