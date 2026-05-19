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
            let pageSections = sections.isEmpty ? [(title: String?.none, parentKey: String?.none, text: page.text)] : sections

            for section in pageSections {
                let units = chooseUnits(section.text)
                var buf = ""
                func flush() {
                    let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let parentId = section.parentKey.map { "\(sourceId):p\(page.index):\($0)" }
                        out.append(Chunk(sourceId: sourceId, page: page.index, text: trimmed, ordinal: ordinal, sectionTitle: section.title, parentId: parentId))
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

private func markdownSections(in text: String) -> [(title: String?, parentKey: String?, text: String)] {
    let lines = text.components(separatedBy: .newlines)
    var sections: [(title: String?, parentKey: String?, text: String)] = []
    var headingStack: [(level: Int, title: String)] = []
    var currentParentKey: String?
    var currentLines: [String] = []
    var sawHeading = false
    var sectionOrdinal = 0

    func flush() {
        let body = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            let titlePath = headingStack.map(\.title).joined(separator: " > ")
            let title = titlePath.isEmpty ? nil : titlePath
            sections.append((title: title, parentKey: currentParentKey, text: body))
        }
        currentLines.removeAll(keepingCapacity: true)
    }

    for line in lines {
        if let heading = markdownHeading(line) {
            sawHeading = true
            flush()
            headingStack.removeAll { $0.level >= heading.level }
            headingStack.append(heading)
            sectionOrdinal += 1
            currentParentKey = "s\(sectionOrdinal)"
        } else {
            currentLines.append(line)
        }
    }

    flush()
    return sawHeading ? sections : []
}

private func markdownHeading(_ line: String) -> (level: Int, title: String)? {
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
    return title.isEmpty ? nil : (markerCount, title)
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
