import Foundation

// MARK: - MXF Header Fallback Parser
//
// Lightweight KLV parser for MXF (Material Exchange Format) file headers.
// Used as a fallback when ffprobe fails — extracts container-level metadata
// (resolution, codec label, duration, frame rate, audio info) directly from
// the MXF header partition without needing to decode the essence.
//
// MXF uses SMPTE KLV (Key-Length-Value) encoding:
//   Key:    16-byte SMPTE Universal Label (UL), always starts 06.0e.2b.34
//   Length: BER-encoded (variable 1-9 bytes)
//   Value:  payload bytes
//
// Reference: SMPTE ST 377-1, ST 379-2, ST 382, ST 384

enum MxfHeaderParser {

    // MARK: - Public Result

    struct MxfMetadata {
        var width: Int = 0
        var height: Int = 0
        var codecLabel: String = ""        // e.g. "Avid Uncompressed 10-bit RGB", "DNxHD"
        var essenceCodingUL: String = ""   // raw UL hex for the picture coding
        var frameRate: String = ""         // e.g. "29.97"
        var sampleRateNum: UInt32 = 0
        var sampleRateDen: UInt32 = 0
        var duration: UInt64 = 0           // in edit units
        var durationSeconds: Double = 0
        var pixelLayout: String = ""       // e.g. "RGBA 10+10+10+2"
        var frameLayout: Int = -1          // 0=full, 1=separate fields, 3=mixed
        var audioChannels: Int = 0
        var audioSampleRate: Int = 0
        var audioBitDepth: Int = 0
        var hasVideo: Bool = false
        var hasAudio: Bool = false
        var descriptorType: String = ""    // "RGBA", "CDCI", "Sound", "Generic"
    }

    // MARK: - Parse

    /// Parse the MXF header of the file at `path` and return metadata.
    /// Only reads the first 256KB — all header metadata lives there.
    /// Returns nil if the file is not a valid MXF.
    static func parse(fileAt path: String) -> MxfMetadata? {
        let headerSize = 256 * 1024
        let data: Data

        // Try mmap first (fast for local files), fall back to read() for network volumes
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }

        var sb = Darwin.stat()
        guard fstat(fd, &sb) == 0, sb.st_size > 16 else { close(fd); return nil }
        let readLen = min(headerSize, Int(sb.st_size))

        if let ptr = mmap(nil, readLen, PROT_READ, MAP_PRIVATE, fd, 0),
           ptr != MAP_FAILED {
            data = Data(bytes: ptr, count: readLen)  // copy out of mmap
            munmap(ptr, readLen)
            close(fd)
        } else {
            // mmap failed (network volume, etc.) — fall back to read()
            var buf = Data(count: readLen)
            let bytesRead = buf.withUnsafeMutableBytes { rawBuf in
                Darwin.read(fd, rawBuf.baseAddress!, readLen)
            }
            close(fd)
            guard bytesRead > 16 else { return nil }
            data = buf.prefix(bytesRead)
        }

        // Verify MXF partition pack key at offset 0
        let mxfPrefix: [UInt8] = [0x06, 0x0e, 0x2b, 0x34]
        guard data.count >= 16,
              data[0] == mxfPrefix[0], data[1] == mxfPrefix[1],
              data[2] == mxfPrefix[2], data[3] == mxfPrefix[3] else {
            return nil
        }

        var meta = MxfMetadata()
        walkKLV(data: data, metadata: &meta)

        // Derive frame rate string
        if meta.sampleRateNum > 0 && meta.sampleRateDen > 0 {
            let fps = Double(meta.sampleRateNum) / Double(meta.sampleRateDen)
            if meta.sampleRateDen == 1 {
                meta.frameRate = "\(meta.sampleRateNum)"
            } else {
                meta.frameRate = String(format: "%.2f", fps)
            }
            // Compute duration in seconds
            if meta.duration > 0 {
                meta.durationSeconds = Double(meta.duration) / fps
            }
        }

        // Derive codec label from essence coding UL if not already set
        if meta.codecLabel.isEmpty && !meta.essenceCodingUL.isEmpty {
            meta.codecLabel = identifyCodec(ul: meta.essenceCodingUL)
        }

        // Mark what we found
        if meta.width > 0 || !meta.essenceCodingUL.isEmpty {
            meta.hasVideo = true
        }
        if meta.audioChannels > 0 || meta.audioBitDepth > 0 {
            meta.hasAudio = true
        }

        return meta
    }

    // MARK: - KLV Walker

    private static func walkKLV(data: Data, metadata: inout MxfMetadata) {
        var pos = 0
        let end = data.count

        while pos < end - 20 {
            // Look for UL prefix
            guard data[pos] == 0x06, data[pos+1] == 0x0e,
                  data[pos+2] == 0x2b, data[pos+3] == 0x34 else {
                pos += 1
                continue
            }

            let keyStart = pos
            let key = Array(data[pos..<pos+16])
            pos += 16

            guard let (length, newPos) = readBER(data: data, pos: pos) else {
                pos = keyStart + 1
                continue
            }
            pos = newPos

            let valStart = pos
            let valEnd = min(pos + length, end)

            // Match descriptor types by their UL
            let keyHex = key.map { String(format: "%02x", $0) }.joined()

            // RGBADescriptor: 060e2b34.0253.0101.0d01.0101.0101.2900
            if keyHex.hasPrefix("060e2b340253") && keyHex.hasSuffix("2900") &&
               keyHex.contains("0d010101") {
                metadata.descriptorType = "RGBA"
                parseDescriptorTags(data: data, start: valStart, end: valEnd, metadata: &metadata)
            }
            // CDCIDescriptor: ...2800
            else if keyHex.hasPrefix("060e2b340253") && keyHex.hasSuffix("2800") &&
                    keyHex.contains("0d010101") {
                metadata.descriptorType = "CDCI"
                parseDescriptorTags(data: data, start: valStart, end: valEnd, metadata: &metadata)
            }
            // GenericPictureEssenceDescriptor: ...2700
            else if keyHex.hasPrefix("060e2b340253") && keyHex.hasSuffix("2700") &&
                    keyHex.contains("0d010101") {
                if metadata.descriptorType.isEmpty { metadata.descriptorType = "Generic" }
                parseDescriptorTags(data: data, start: valStart, end: valEnd, metadata: &metadata)
            }
            // Sound descriptors: GenericSound ...4200/4700, WAVEAudio ...4800, AES3 ...4700, Generic ...2500
            else if keyHex.hasPrefix("060e2b340253") && keyHex.contains("0d010101") &&
                    (keyHex.hasSuffix("4200") || keyHex.hasSuffix("4700") ||
                     keyHex.hasSuffix("4800") || keyHex.hasSuffix("2500")) {
                metadata.descriptorType = metadata.descriptorType.isEmpty ? "Sound" : metadata.descriptorType
                parseSoundDescriptorTags(data: data, start: valStart, end: valEnd, metadata: &metadata)
            }

            if length > 0 && length < data.count {
                pos = valEnd
            } else {
                pos = keyStart + 1
            }
        }
    }

    // MARK: - Descriptor Tag Parsing

    /// Parse local tags within a picture descriptor set.
    /// Local tags are: 2-byte tag (BE) + 2-byte length (BE) + value
    private static func parseDescriptorTags(data: Data, start: Int, end: Int, metadata: inout MxfMetadata) {
        var pos = start
        while pos < end - 4 {
            let tag = readU16BE(data: data, pos: pos)
            let tlen = Int(readU16BE(data: data, pos: pos + 2))
            pos += 4

            guard pos + tlen <= end else { break }

            switch tag {
            case 0x3203: // Stored Width
                if tlen >= 4 { metadata.width = Int(readU32BE(data: data, pos: pos)) }
            case 0x3202: // Stored Height
                if tlen >= 4 { metadata.height = Int(readU32BE(data: data, pos: pos)) }
            case 0x320E: // Frame Layout
                if tlen >= 1 { metadata.frameLayout = Int(data[pos]) }
            case 0x3201: // Picture Essence Coding UL
                if tlen >= 16 {
                    let ul = Array(data[pos..<pos+16])
                    metadata.essenceCodingUL = ul.map { String(format: "%02x", $0) }.joined()
                    metadata.codecLabel = identifyCodec(ul: metadata.essenceCodingUL)
                }
            case 0x3001: // Sample Rate (rational num/den)
                if tlen >= 8 {
                    metadata.sampleRateNum = readU32BE(data: data, pos: pos)
                    metadata.sampleRateDen = readU32BE(data: data, pos: pos + 4)
                }
            case 0x3002: // Container Duration
                if tlen >= 8 {
                    metadata.duration = readU64BE(data: data, pos: pos)
                } else if tlen >= 4 {
                    metadata.duration = UInt64(readU32BE(data: data, pos: pos))
                }
            case 0x3401: // Pixel Layout
                if tlen >= 2 {
                    metadata.pixelLayout = decodePixelLayout(data: data, pos: pos, len: tlen)
                }
            default:
                break
            }
            pos += tlen
        }
    }

    /// Parse local tags within a sound descriptor set.
    private static func parseSoundDescriptorTags(data: Data, start: Int, end: Int, metadata: inout MxfMetadata) {
        var pos = start
        while pos < end - 4 {
            let tag = readU16BE(data: data, pos: pos)
            let tlen = Int(readU16BE(data: data, pos: pos + 2))
            pos += 4

            guard pos + tlen <= end else { break }

            switch tag {
            case 0x3D07: // Channel Count
                if tlen >= 4 { metadata.audioChannels = Int(readU32BE(data: data, pos: pos)) }
            case 0x3D03: // Audio Sampling Rate (rational)
                if tlen >= 8 {
                    let num = readU32BE(data: data, pos: pos)
                    let den = readU32BE(data: data, pos: pos + 4)
                    metadata.audioSampleRate = den > 0 ? Int(num / den) : Int(num)
                }
            case 0x3D01: // Quantization Bits
                if tlen >= 4 { metadata.audioBitDepth = Int(readU32BE(data: data, pos: pos)) }
            case 0x3001: // Sample Rate
                if tlen >= 8 && metadata.sampleRateNum == 0 {
                    metadata.sampleRateNum = readU32BE(data: data, pos: pos)
                    metadata.sampleRateDen = readU32BE(data: data, pos: pos + 4)
                }
            case 0x3002: // Container Duration
                if tlen >= 8 && metadata.duration == 0 {
                    metadata.duration = readU64BE(data: data, pos: pos)
                } else if tlen >= 4 && metadata.duration == 0 {
                    metadata.duration = UInt64(readU32BE(data: data, pos: pos))
                }
            default:
                break
            }
            pos += tlen
        }
    }

    // MARK: - Codec Identification

    /// Map a Picture Essence Coding UL to a human-readable codec name.
    /// The UL encodes the codec family in bytes 8-15 per SMPTE RP 224.
    private static func identifyCodec(ul: String) -> String {
        // UL format: 060e2b34.0401.01xx.0401.0202.xx.xx.xx.xx.xx.xx
        // Bytes 12-15 identify the codec

        // Avid private ULs (byte 8 = 0e)
        if ul.hasPrefix("060e2b340401") && ul.count >= 20 {
            let byte8 = ul.dropFirst(14).prefix(2)
            if byte8 == "0e" {
                // Avid proprietary codec
                return "Avid Uncompressed"
            }
        }

        // Well-known picture coding ULs (bytes 12-13 area)
        let essenceArea = String(ul.dropFirst(16).prefix(8))  // bytes 9-12

        // Uncompressed
        if essenceArea.hasPrefix("04010201") { return "Uncompressed" }

        // DV family (04.01.02.02.02)
        if essenceArea.hasPrefix("04010202") {
            if ul.contains("0201") { return "DV 25" }
            if ul.contains("0202") { return "DVCPRO" }
            return "DV"
        }

        // MPEG-2 (04.01.02.02.01)
        if essenceArea.hasPrefix("04010201") && ul.count > 28 {
            return "MPEG-2"
        }

        // DNxHD / DNxHR — Avid VC-3 family
        // SMPTE VC-3: 060e2b34.0401.0109.0401.0202.0371.0xxx
        if ul.contains("0371") || ul.contains("0301") {
            return "DNxHD"
        }

        // JPEG 2000
        if essenceArea.hasPrefix("04010202") && ul.contains("0301") {
            return "JPEG 2000"
        }

        // H.264 / AVC
        if ul.contains("04010203") || ul.contains("f31301") {
            return "H.264"
        }

        // ProRes
        if ul.contains("04010202") && ul.contains("0601") {
            return "ProRes"
        }

        // Avid-specific: check for common patterns
        if ul.hasPrefix("060e2b34040101") {
            // Byte 8 indicates registry version, byte 9+ the item
            let itemArea = String(ul.dropFirst(14))
            if itemArea.hasPrefix("0e") {
                return "Avid Uncompressed"
            }
        }

        // Raw/uncompressed video
        if ul.contains("05010101") || ul.contains("05010201") {
            return "Uncompressed"
        }

        return "Unknown (\(ul.prefix(24))…)"
    }

    /// Decode the Pixel Layout array into a readable string.
    /// Format: pairs of (component_code, bit_depth) terminated by (0,0)
    /// Component codes: 'R'=0x52, 'G'=0x47, 'B'=0x42, 'F'(fill)=0x46, 'A'(alpha)=0x41
    private static func decodePixelLayout(data: Data, pos: Int, len: Int) -> String {
        var components: [(String, Int)] = []
        var i = pos
        let end = pos + len
        while i + 1 < end {
            let code = data[i]
            let bits = Int(data[i + 1])
            if code == 0 && bits == 0 { break }
            let name: String
            switch code {
            case 0x52: name = "R"
            case 0x47: name = "G"
            case 0x42: name = "B"
            case 0x41: name = "A"
            case 0x46: name = "F"
            case 0x59: name = "Y"
            default:   name = String(format: "0x%02X", code)
            }
            components.append((name, bits))
            i += 2
        }
        if components.isEmpty { return "" }
        let names = components.map { $0.0 }.joined()
        let depths = components.map { "\($0.1)" }.joined(separator: "+")
        return "\(names) \(depths)"
    }

    // MARK: - Binary Helpers

    private static func readU16BE(data: Data, pos: Int) -> UInt16 {
        UInt16(data[pos]) << 8 | UInt16(data[pos + 1])
    }

    private static func readU32BE(data: Data, pos: Int) -> UInt32 {
        UInt32(data[pos]) << 24 | UInt32(data[pos+1]) << 16 |
        UInt32(data[pos+2]) << 8 | UInt32(data[pos+3])
    }

    private static func readU64BE(data: Data, pos: Int) -> UInt64 {
        UInt64(data[pos]) << 56 | UInt64(data[pos+1]) << 48 |
        UInt64(data[pos+2]) << 40 | UInt64(data[pos+3]) << 32 |
        UInt64(data[pos+4]) << 24 | UInt64(data[pos+5]) << 16 |
        UInt64(data[pos+6]) << 8  | UInt64(data[pos+7])
    }

    /// Read a BER-encoded length. Returns (length, newPosition) or nil on error.
    private static func readBER(data: Data, pos: Int) -> (Int, Int)? {
        guard pos < data.count else { return nil }
        let first = data[pos]
        if first < 0x80 {
            return (Int(first), pos + 1)
        }
        let nBytes = Int(first & 0x7F)
        guard nBytes > 0, nBytes <= 8, pos + 1 + nBytes <= data.count else { return nil }
        var length: Int = 0
        for i in 0..<nBytes {
            length = (length << 8) | Int(data[pos + 1 + i])
        }
        return (length, pos + 1 + nBytes)
    }
}
