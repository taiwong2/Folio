//
//  ImageDocumentLoader.swift
//  Folio
//

import Foundation
import CoreGraphics
import ImageIO
#if canImport(Vision)
import Vision
#endif

public struct ImageDocumentLoader: DocumentLoader {
    static let supportedUTIs: Set<String> = [
        "public.jpeg",
        "public.png",
        "public.heif",
        "public.heic",
        "public.tiff",
        "com.compuserve.gif",
        "org.webmproject.webp"
    ]

    public init() {}

    public func supports(_ input: IngestInput) -> Bool {
        guard case let .data(_, uti, _) = input else { return false }
        let normalized = uti.lowercased()
        if normalized == "public.image" { return true }
        return ImageDocumentLoader.supportedUTIs.contains(normalized)
    }

    public func load(_ input: IngestInput) throws -> LoadedDocument {
        guard case let .data(data, _, name) = input else {
            throw NSError(domain: "Folio", code: 407, userInfo: [NSLocalizedDescriptionKey: "Not an image"])
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "Folio", code: 408, userInfo: [NSLocalizedDescriptionKey: "Could not decode image"])
        }

        let text = (try? performOCR(on: cgImage)) ?? ""
        return LoadedDocument(name: name ?? "image", pages: [.init(index: 0, text: text)])
    }

    #if canImport(Vision)
    @available(iOS 13.0, macOS 10.15, *)
    private func performOCR(on image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        return (request.results ?? [])
            .flatMap { result in result.topCandidates(1).map(\.string) }
            .joined(separator: "\n")
    }
    #else
    private func performOCR(on image: CGImage) throws -> String { "" }
    #endif
}
