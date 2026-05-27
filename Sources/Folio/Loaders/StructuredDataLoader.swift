//
//  StructuredDataLoader.swift
//  Folio
//
//  Loader for JSON, XML, and YAML. Each format is flattened into a sequence of
//  "path.to.key: value" lines so the resulting document is searchable by key
//  name and by value. JSON uses Foundation's `JSONSerialization`; XML uses
//  `XMLParser`; YAML is parsed with a deliberately small line-based heuristic
//  that handles the most common `key: value` and `- item` shapes without
//  pulling in a third-party parser.
//

import Foundation

public struct StructuredDataLoader: DocumentLoader {
    private let supportedUTIs: Set<String> = [
        "public.json",
        "public.xml",
        "public.yaml"
    ]

    public init() {}

    public func supports(_ input: IngestInput) -> Bool {
        guard case let .data(_, uti, _) = input else { return false }
        return supportedUTIs.contains(uti.lowercased())
    }

    public func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .data(data, uti, name) = input, supportedUTIs.contains(uti.lowercased()) else {
            throw NSError(domain: "Folio", code: 403, userInfo: [NSLocalizedDescriptionKey: "Not JSON/XML/YAML"])
        }

        let lines: [String]
        switch uti.lowercased() {
        case "public.json": lines = try Self.flattenJSON(data)
        case "public.xml":  lines = try Self.flattenXML(data)
        case "public.yaml": lines = Self.flattenYAML(data)
        default:
            throw NSError(domain: "Folio", code: 403, userInfo: [NSLocalizedDescriptionKey: "Unsupported UTI"])
        }

        let displayName = name ?? Self.defaultName(for: uti)
        return LoadedDocument(name: displayName, pages: [.init(index: 0, text: lines.joined(separator: "\n"))])
    }

    private static func defaultName(for uti: String) -> String {
        switch uti.lowercased() {
        case "public.json": return "untitled.json"
        case "public.xml":  return "untitled.xml"
        case "public.yaml": return "untitled.yaml"
        default:            return "untitled"
        }
    }

    // MARK: - JSON

    static func flattenJSON(_ data: Data) throws -> [String] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        var out: [String] = []
        walkJSON(obj, path: "", into: &out)
        return out
    }

    private static func walkJSON(_ obj: Any, path: String, into out: inout [String]) {
        if let dict = obj as? [String: Any] {
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                let next = path.isEmpty ? k : "\(path).\(k)"
                walkJSON(v, path: next, into: &out)
            }
        } else if let arr = obj as? [Any] {
            for (i, v) in arr.enumerated() {
                walkJSON(v, path: "\(path)[\(i)]", into: &out)
            }
        } else if obj is NSNull {
            out.append("\(path): null")
        } else {
            out.append("\(path): \(obj)")
        }
    }

    // MARK: - XML

    static func flattenXML(_ data: Data) throws -> [String] {
        let collector = XMLFlattenCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else {
            let err = parser.parserError ?? NSError(domain: "Folio", code: 405)
            throw err
        }
        return collector.lines
    }

    // MARK: - YAML

    static func flattenYAML(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = String(rawLine)
            if let hash = s.firstIndex(of: "#") {
                s = String(s[..<hash])
            }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == "---" || trimmed == "..." { continue }
            out.append(trimmed)
        }
        return out
    }
}

private final class XMLFlattenCollector: NSObject, XMLParserDelegate {
    private(set) var lines: [String] = []
    private var path: [String] = []
    private var buffer = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        path.append(elementName)
        let pathString = path.joined(separator: ".")
        for (k, v) in attributeDict.sorted(by: { $0.key < $1.key }) {
            lines.append("\(pathString).@\(k): \(v)")
        }
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("\(path.joined(separator: ".")): \(trimmed)")
        }
        if !path.isEmpty { path.removeLast() }
        buffer = ""
    }
}
