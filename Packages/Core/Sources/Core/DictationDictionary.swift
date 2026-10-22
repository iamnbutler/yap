import Foundation

/// The words dictation should spell your way.
///
/// Read from `dictionary.txt` in the support directory, one entry per line:
///
///     # comment
///     Yap                       a term: sent to the model as vocabulary
///     auto blog => autoblog     a fix: replaced in the transcript afterwards
///
/// Two kinds because the vocabulary prompt only biases the model. It fixed
/// "gpuiTunes" and "Iosevka" outright, but "autoblog" still came back as
/// "auto blog" every time, and only a replacement after the fact catches that.
///
/// Only the first `promptLimit` terms are sent, so the file's order is its
/// priority. More vocabulary is worse, not merely wasted: on gpt-transcribe,
/// twelve hard words across three sentences came back right 6/24 times with no
/// prompt, 18/24 with the top 15 or 25 terms, 16/24 with 80 and 14/24 with all
/// 153. A long list dilutes every term in it, wherever it sits.
public struct DictationDictionary: Sendable, Equatable {
    public static let promptLimit = 25

    public var terms: [String]
    public var fixes: [(heard: String, written: String)]

    public static var file: URL {
        Paths.support.appendingPathComponent("dictionary.txt")
    }

    public init(terms: [String] = [], fixes: [(heard: String, written: String)] = []) {
        self.terms = terms
        self.fixes = fixes
    }

    /// The file's contents, or an empty dictionary when there is no file.
    public static func load(from url: URL = file) -> DictationDictionary {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return .init() }
        return parse(contents)
    }

    public static func parse(_ contents: String) -> DictationDictionary {
        var dictionary = DictationDictionary()
        for raw in contents.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if let arrow = line.range(of: "=>") {
                let heard = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let written = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !heard.isEmpty else { continue }
                dictionary.fixes.append((heard, written))
            } else {
                dictionary.terms.append(line)
            }
        }
        return dictionary
    }

    /// The prompt that carries the terms. Nil with no terms, so the request
    /// leaves the field out rather than sending a list with nothing in it.
    public var prompt: String? {
        guard !terms.isEmpty else { return nil }
        return "Dictated into a Claude Code terminal session. Vocabulary: "
            + terms.prefix(Self.promptLimit).joined(separator: ", ") + "."
    }

    /// Applies every fix, matching whole words regardless of case.
    public func apply(to text: String) -> String {
        fixes.reduce(text) { text, fix in
            let pattern = "(?<![\\w-])" + NSRegularExpression.escapedPattern(for: fix.heard)
                + "(?![\\w-])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { return text }
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: fix.written))
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.terms == rhs.terms
            && lhs.fixes.map { [$0.heard, $0.written] } == rhs.fixes.map { [$0.heard, $0.written] }
    }
}
