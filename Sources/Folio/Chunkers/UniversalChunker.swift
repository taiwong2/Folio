//
//  UniversalChunker.swift
//  Folio
//
//  Created by Tai Wong on 9/13/25.
//


import Foundation
import NaturalLanguage

public struct UniversalChunker: Chunker {
    public init() {}
    public func chunk(sourceId: String, doc: LoadedDocument, config: ChunkingConfig) throws -> [Chunk] {
        let maxChars = max(200, Int(Double(config.maxTokensPerChunk) * 3.6))
        let overlapChars = max(0, Int(Double(config.overlapTokens) * 3.6))

        var out: [Chunk] = []
        var ordinal = 0
        for page in doc.pages {
            let sections = markdownSections(in: page.text)
            let pageSections = sections.isEmpty ? [(title: String?.none, text: page.text)] : sections

            for section in pageSections {
                let units = chooseUnits(section.text)
                var buf = ""
                func flush() {
                    let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        out.append(Chunk(sourceId: sourceId, page: page.index, text: trimmed, ordinal: ordinal, sectionTitle: section.title))
                        ordinal += 1
                    }

                    buf.removeAll(keepingCapacity: true)
                }
                for u in units {
                    if buf.isEmpty { buf = u; continue }
                    if (buf.count + 1 + u.count) > maxChars {
                        flush()
                        if overlapChars > 0, let last = out.last {
                            let carry = String(last.text.suffix(overlapChars))
                            buf = (carry.isEmpty ? "" : carry + "\n") + u
                            if buf.count > maxChars { buf = u }
                        } else { buf = u }
                    } else {
                        buf += (looksTableish(section.text) ? "\n" : " ") + u
                    }
                }
                if !buf.isEmpty { flush() }
            }
        }
        return out
    }
}

private func markdownSections(in text: String) -> [(title: String?, text: String)] {
    let lines = text.components(separatedBy: .newlines)
    var sections: [(title: String?, text: String)] = []
    var currentTitle: String?
    var currentLines: [String] = []
    var sawHeading = false

    func flush() {
        let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            sections.append((title: currentTitle, text: body))
        }
        currentLines.removeAll(keepingCapacity: true)
    }

    for line in lines {
        if let heading = markdownHeadingTitle(line) {
            sawHeading = true
            flush()
            currentTitle = heading
        } else {
            currentLines.append(line)
        }
    }

    flush()
    return sawHeading ? sections : []
}

private func markdownHeadingTitle(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("#") else { return nil }

    var markerCount = 0
    for character in trimmed {
        if character == "#" {
            markerCount += 1
        } else {
            break
        }
    }

    guard (1...6).contains(markerCount) else { return nil }
    let afterMarkers = trimmed.dropFirst(markerCount)
    guard afterMarkers.first == " " else { return nil }

    let title = afterMarkers.trimmingCharacters(in: .whitespaces)
    return title.isEmpty ? nil : title
}

private func chooseUnits(_ text: String) -> [String] {
    if looksTableish(text) { return splitLines(text) }
    return splitSentences(text)
}
private func splitSentences(_ text: String) -> [String] {
    var out: [String] = []; let tok = NLTokenizer(unit: .sentence); tok.string = text
    tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
        let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }; return true
    }
    return out
}
private func splitLines(_ text: String) -> [String] {
    text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
}

private let tableHintRE = try! NSRegularExpression(pattern: #"(?i)[\t\|]|(\S+\s{2,}\S+)"#)
private func looksTableish(_ s: String) -> Bool {
    tableHintRE.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
}
