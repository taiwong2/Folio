//
//  ZipExtractor.swift
//  Folio
//

import Foundation
import Compression

/// Minimal read-only ZIP extractor for the single-file case (e.g. pulling
/// `word/document.xml` out of a `.docx`). Walks the central directory so it
/// handles entries written with the streaming "data descriptor" mode that
/// modern Office producers use. Supports `STORED` (0) and `DEFLATE` (8); throws
/// on ZIP64, encryption, or anything else, since DOCX produced by Word and
/// LibreOffice fits within the classic layout.
enum ZipExtractor {

    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)
        case unsupported(String)
        case entryNotFound(String)
        case decompressionFailed

        var description: String {
            switch self {
            case .malformed(let r): return "Malformed ZIP: \(r)"
            case .unsupported(let r): return "Unsupported ZIP feature: \(r)"
            case .entryNotFound(let n): return "ZIP entry not found: \(n)"
            case .decompressionFailed: return "ZIP decompression failed"
            }
        }
    }

    /// Extracts the contents of `name` (path inside the archive, case-sensitive) from `data`.
    static func extract(_ name: String, from data: Data) throws -> Data {
        let eocdOffset = try findEOCD(in: data)
        let cd = try readEOCD(data: data, at: eocdOffset)

        var offset = cd.centralDirectoryOffset
        for _ in 0..<cd.entryCount {
            let entry = try readCentralDirectoryEntry(data: data, at: offset)
            offset = entry.nextOffset
            if entry.filename == name {
                return try readPayload(data: data, entry: entry)
            }
        }
        throw Error.entryNotFound(name)
    }

    // MARK: - EOCD

    /// EOCD signature: `0x06054b50`. The record sits at most 65 557 bytes from the end
    /// (22-byte fixed header + 65 535-byte max comment), so scan a window of that size.
    private static func findEOCD(in data: Data) throws -> Int {
        let signature: UInt32 = 0x06054b50
        let minLen = 22
        guard data.count >= minLen else { throw Error.malformed("file too small") }

        let scanStart = max(0, data.count - (minLen + 0xFFFF))
        var i = data.count - minLen
        while i >= scanStart {
            if readUInt32(data, at: i) == signature {
                let commentLen = Int(readUInt16(data, at: i + 20))
                if i + minLen + commentLen == data.count {
                    return i
                }
            }
            i -= 1
        }
        throw Error.malformed("EOCD not found")
    }

    private struct CDInfo {
        let entryCount: Int
        let centralDirectoryOffset: Int
    }

    private static func readEOCD(data: Data, at offset: Int) throws -> CDInfo {
        let totalEntries = Int(readUInt16(data, at: offset + 10))
        let cdSize = Int(readUInt32(data, at: offset + 12))
        let cdOffset = Int(readUInt32(data, at: offset + 16))
        if totalEntries == 0xFFFF || cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF {
            throw Error.unsupported("ZIP64 (file is too large for the classic central directory)")
        }
        return CDInfo(entryCount: totalEntries, centralDirectoryOffset: cdOffset)
    }

    // MARK: - Central directory entries

    private struct CDEntry {
        let filename: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let generalPurposeBitFlag: UInt16
        let nextOffset: Int
    }

    private static func readCentralDirectoryEntry(data: Data, at offset: Int) throws -> CDEntry {
        let signature: UInt32 = 0x02014b50
        guard readUInt32(data, at: offset) == signature else {
            throw Error.malformed("bad central directory signature at \(offset)")
        }
        let gpFlag = readUInt16(data, at: offset + 8)
        let method = readUInt16(data, at: offset + 10)
        let compressed = Int(readUInt32(data, at: offset + 20))
        let uncompressed = Int(readUInt32(data, at: offset + 24))
        let nameLen = Int(readUInt16(data, at: offset + 28))
        let extraLen = Int(readUInt16(data, at: offset + 30))
        let commentLen = Int(readUInt16(data, at: offset + 32))
        let localOffset = Int(readUInt32(data, at: offset + 42))

        if compressed == 0xFFFFFFFF || uncompressed == 0xFFFFFFFF || localOffset == 0xFFFFFFFF {
            throw Error.unsupported("ZIP64 entry")
        }
        if gpFlag & 0x0001 != 0 {
            throw Error.unsupported("encrypted entry")
        }

        let nameStart = offset + 46
        let nameEnd = nameStart + nameLen
        guard nameEnd <= data.count else { throw Error.malformed("filename overruns archive") }
        let nameBytes = data.subdata(in: nameStart..<nameEnd)
        let filename = String(data: nameBytes, encoding: .utf8) ?? ""

        return CDEntry(
            filename: filename,
            compressionMethod: method,
            compressedSize: compressed,
            uncompressedSize: uncompressed,
            localHeaderOffset: localOffset,
            generalPurposeBitFlag: gpFlag,
            nextOffset: nameEnd + extraLen + commentLen
        )
    }

    // MARK: - Payload

    private static func readPayload(data: Data, entry: CDEntry) throws -> Data {
        let lfhSignature: UInt32 = 0x04034b50
        let lfhOffset = entry.localHeaderOffset
        guard readUInt32(data, at: lfhOffset) == lfhSignature else {
            throw Error.malformed("bad local file header signature at \(lfhOffset)")
        }
        let lfhNameLen = Int(readUInt16(data, at: lfhOffset + 26))
        let lfhExtraLen = Int(readUInt16(data, at: lfhOffset + 28))
        let payloadStart = lfhOffset + 30 + lfhNameLen + lfhExtraLen
        let payloadEnd = payloadStart + entry.compressedSize
        guard payloadEnd <= data.count else { throw Error.malformed("payload overruns archive") }

        let compressed = data.subdata(in: payloadStart..<payloadEnd)

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflateRawDeflate(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw Error.unsupported("compression method \(entry.compressionMethod)")
        }
    }

    /// Decodes a raw DEFLATE bitstream. ZIP stores raw DEFLATE (no zlib wrapper), which
    /// matches `COMPRESSION_ZLIB` in Apple's `Compression` framework despite the name.
    private static func inflateRawDeflate(_ data: Data, expectedSize: Int) throws -> Data {
        // Apple's buffer-based decoder needs a destination at least as large as the
        // payload. Pad slightly above the declared uncompressed size to absorb any
        // codec round-tripping; if the entry claims zero (rare), fall back to 4 KB.
        let destCapacity = max(expectedSize + 16, 4096)
        var output = Data(count: destCapacity)
        let produced = output.withUnsafeMutableBytes { destBuf -> Int in
            data.withUnsafeBytes { srcBuf -> Int in
                guard let dest = destBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let src = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(dest, destCapacity, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard produced > 0 else { throw Error.decompressionFailed }
        output.removeSubrange(produced..<output.count)
        return output
    }

    // MARK: - Little-endian readers

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        precondition(offset + 2 <= data.count, "out of bounds UInt16 read")
        return data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
            return UInt16(base[0]) | (UInt16(base[1]) << 8)
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        precondition(offset + 4 <= data.count, "out of bounds UInt32 read")
        return data.withUnsafeBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
            return UInt32(base[0])
                | (UInt32(base[1]) << 8)
                | (UInt32(base[2]) << 16)
                | (UInt32(base[3]) << 24)
        }
    }
}
