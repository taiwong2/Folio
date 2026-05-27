//
//  CSVDocumentLoader.swift
//  Folio
//
//  Loader for CSV and TSV. RFC-4180-style parsing (double-quoted fields with
//  doubled quotes as an escape, optional CRLF line endings, embedded newlines
//  inside quotes). The first row is treated as a header; each subsequent row
//  becomes its own `LoadedPage` formatted as `col: val, col: val, ...` so that
//  individual rows surface as their own search hits with the column names
//  carried along for context.
//

import Foundation

public struct CSVDocumentLoader: DocumentLoader {
    private let supportedUTIs: Set<String> = [
        "public.comma-separated-values-text",
        "public.tab-separated-values-text"
    ]

    public init() {}

    public func supports(_ input: IngestInput) -> Bool {
        guard case let .data(_, uti, _) = input else { return false }
        return supportedUTIs.contains(uti.lowercased())
    }

    public func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .data(data, uti, name) = input, supportedUTIs.contains(uti.lowercased()) else {
            throw NSError(domain: "Folio", code: 403, userInfo: [NSLocalizedDescriptionKey: "Not CSV/TSV"])
        }

        guard let raw = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Folio", code: 404, userInfo: [NSLocalizedDescriptionKey: "CSV/TSV must be UTF-8"])
        }

        let delimiter: Character = uti.lowercased() == "public.tab-separated-values-text" ? "\t" : ","
        let rows = Self.parse(raw, delimiter: delimiter)
        let displayName = name ?? (delimiter == "\t" ? "untitled.tsv" : "untitled.csv")

        guard let header = rows.first else {
            return LoadedDocument(name: displayName, pages: [])
        }

        let dataRows = rows.dropFirst()
        var pages: [LoadedPage] = []
        for (offset, row) in dataRows.enumerated() {
            var parts: [String] = []
            for (col, value) in row.enumerated() {
                let key = col < header.count ? header[col] : "col\(col + 1)"
                parts.append("\(key): \(value)")
            }
            pages.append(.init(index: offset + 1, text: parts.joined(separator: ", ")))
        }
        return LoadedDocument(name: displayName, pages: pages)
    }

    /// RFC-4180-style CSV parser parameterised by delimiter. Empty trailing
    /// lines are dropped. Quoted fields may contain newlines and escaped
    /// quotes (`""`).
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var current: [String] = []
        var field = ""
        var inQuotes = false

        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == delimiter {
                    current.append(field)
                    field = ""
                } else if ch == "\n" || ch == "\r" {
                    current.append(field)
                    field = ""
                    if !(current.count == 1 && current[0].isEmpty) {
                        rows.append(current)
                    }
                    current = []
                    if ch == "\r" {
                        let next = text.index(after: i)
                        if next < text.endIndex && text[next] == "\n" {
                            i = next
                        }
                    }
                } else {
                    field.append(ch)
                }
            }
            i = text.index(after: i)
        }

        current.append(field)
        if !(current.count == 1 && current[0].isEmpty) {
            rows.append(current)
        }
        return rows
    }
}
