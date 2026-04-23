// AvbParser.swift
// Native Swift parser for Avid .avb (bin) files.
//
// Reverse-engineered binary format based on pyavb by Mark Reid (MIT license).
// The .avb format descends from OMF (Open Media Framework) and stores clip
// metadata, MobIDs (SMPTE UMIDs), media file paths, tape names, timecodes,
// and track structures that link Avid project bins to their MXF media files.
//
// This parser is read-only and extracts only the metadata needed for
// VideoScan's media recovery workflow.

import Foundation

// MARK: - Public Data Types

/// A single clip entry extracted from an Avid bin file.
struct AvbClip: Identifiable {
    let id = UUID()
    let clipName: String
    let mobType: String          // "CompositionMob", "MasterMob", "SourceMob"
    let mobID: String            // SMPTE UMID as URN string
    let materialUUID: String     // 16-byte material number as UUID string
    let tapeName: String
    let creationDate: Date?
    let lastModified: Date?
    let editRate: Double
    let duration: Int            // in edit-rate units
    let tracks: [AvbTrack]
    let mediaPath: String        // FileLocator path (original MXF location)
    let mediaPathPosix: String
    let descriptorType: String   // e.g. "CDCI", "WAVE", "MDTP" (tape), etc.
    let binFileName: String      // which .avb file this came from
}

/// A track within a mob.
struct AvbTrack {
    let index: Int
    let mediaKind: String   // "picture", "sound", "timecode", "edgecode", etc.
    let startPos: Int
    let length: Int
    let sourceClipMobID: String  // MobID of the referenced mob (for chasing references)
    let sourceTrackID: Int
}

/// Summary of an entire .avb file parse.
struct AvbBinResult {
    let filePath: String
    let binName: String        // derived from filename
    let creatorVersion: String
    let lastSave: Date?
    let clips: [AvbClip]
    let errors: [String]
}

// MARK: - Binary Reader

/// Low-level binary reader with endian-aware primitives.
private class BinaryReader {
    let data: Data
    var offset: Int = 0
    let littleEndian: Bool

    init(data: Data, littleEndian: Bool) {
        self.data = data
        self.littleEndian = littleEndian
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { offset >= data.count }

    func readBytes(_ count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        let slice = data[offset..<offset+count]
        offset += count
        return Data(slice)
    }

    func readU8() -> UInt8? {
        guard offset < data.count else { return nil }
        let v = data[offset]
        offset += 1
        return v
    }

    func readS8() -> Int8? {
        guard let u = readU8() else { return nil }
        return Int8(bitPattern: u)
    }

    func readU16() -> UInt16? {
        guard let bytes = readBytes(2) else { return nil }
        return littleEndian
            ? UInt16(bytes[bytes.startIndex]) | (UInt16(bytes[bytes.startIndex+1]) << 8)
            : (UInt16(bytes[bytes.startIndex]) << 8) | UInt16(bytes[bytes.startIndex+1])
    }

    func readS16() -> Int16? {
        guard let u = readU16() else { return nil }
        return Int16(bitPattern: u)
    }

    func readU32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        let b = bytes.startIndex
        if littleEndian {
            return UInt32(bytes[b]) | (UInt32(bytes[b+1]) << 8) |
                   (UInt32(bytes[b+2]) << 16) | (UInt32(bytes[b+3]) << 24)
        } else {
            return (UInt32(bytes[b]) << 24) | (UInt32(bytes[b+1]) << 16) |
                   (UInt32(bytes[b+2]) << 8) | UInt32(bytes[b+3])
        }
    }

    func readS32() -> Int32? {
        guard let u = readU32() else { return nil }
        return Int32(bitPattern: u)
    }

    func readU64() -> UInt64? {
        guard let bytes = readBytes(8) else { return nil }
        let b = bytes.startIndex
        if littleEndian {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[b+i]) << (i * 8) }
            return v
        } else {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[b+i]) << ((7 - i) * 8) }
            return v
        }
    }

    func readBool() -> Bool? {
        guard let v = readU8() else { return nil }
        return v == 0x01
    }

    func readFourCC() -> String? {
        guard let bytes = readBytes(4) else { return nil }
        if littleEndian {
            // Reverse for LE
            return String(bytes: [bytes[3], bytes[2], bytes[1], bytes[0]], encoding: .ascii)
        } else {
            return String(data: bytes, encoding: .ascii)
        }
    }

    func readString(encoding: String.Encoding = .macOSRoman) -> String? {
        guard let size = readU16() else { return nil }
        if size >= 0xFFFF { return "" }
        guard let bytes = readBytes(Int(size)) else { return nil }
        let trimmed = bytes.filter { $0 != 0 }
        return String(data: Data(trimmed), encoding: encoding) ?? ""
    }

    func readExp10Float() -> Double? {
        guard let mantissa = readS32(), let exp10 = readS16() else { return nil }
        return Double(mantissa) * pow(10.0, Double(exp10))
    }

    func readDateTime() -> Date? {
        guard let ts = readU32() else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// Read a SMPTE MobID (32 bytes total: 12-byte label + length + 3 instance + 16-byte material UUID)
    func readMobID() -> (urn: String, materialUUID: String)? {
        // Tag 65 + s32 length (should be 12) + 12 bytes SMPTE label
        guard let tag1 = readU8(), tag1 == 65,
              let labelLen = readS32(), labelLen == 12,
              let labelBytes = readBytes(12) else { return nil }

        // Tag 68 + length byte
        guard let t2 = readU8(), t2 == 68, let length = readU8() else { return nil }
        guard let t3 = readU8(), t3 == 68, let instHigh = readU8() else { return nil }
        guard let t4 = readU8(), t4 == 68, let instMid = readU8() else { return nil }
        guard let t5 = readU8(), t5 == 68, let instLow = readU8() else { return nil }

        // Material UUID: tag72 + u32 + tag70 + u16 + tag70 + u16 + tag65 + s32(8) + 8 bytes
        guard let t6 = readU8(), t6 == 72, let data1 = readU32() else { return nil }
        guard let t7 = readU8(), t7 == 70, let data2 = readU16() else { return nil }
        guard let t8 = readU8(), t8 == 70, let data3 = readU16() else { return nil }
        guard let t9 = readU8(), t9 == 65, let d4Len = readS32(), d4Len == 8,
              let data4 = readBytes(8) else { return nil }

        let label = [UInt8](labelBytes)
        let d4 = [UInt8](data4)

        // Build URN string (SMPTE format)
        let urn = String(format:
            "urn:smpte:umid:%02x%02x%02x%02x.%02x%02x%02x%02x.%02x%02x%02x%02x.%02x%02x%02x%02x.%08x.%04x%04x.%02x%02x%02x%02x.%02x%02x%02x%02x",
            label[0], label[1], label[2], label[3],
            label[4], label[5], label[6], label[7],
            label[8], label[9], label[10], label[11],
            length, instHigh, instMid, instLow,
            data1, data2, data3,
            d4[0], d4[1], d4[2], d4[3],
            d4[4], d4[5], d4[6], d4[7])

        // Material UUID — construct from the data1/data2/data3/data4 components
        // This matches how pyavb creates uuid.UUID(bytes_le=bytes_le[16:])
        let uuidStr: String
        if littleEndian {
            // bytes_le layout: data1(4 LE) + data2(2 LE) + data3(2 LE) + data4(8)
            var uuidBytes = [UInt8](repeating: 0, count: 16)
            uuidBytes[0] = UInt8(data1 & 0xFF)
            uuidBytes[1] = UInt8((data1 >> 8) & 0xFF)
            uuidBytes[2] = UInt8((data1 >> 16) & 0xFF)
            uuidBytes[3] = UInt8((data1 >> 24) & 0xFF)
            uuidBytes[4] = UInt8(data2 & 0xFF)
            uuidBytes[5] = UInt8((data2 >> 8) & 0xFF)
            uuidBytes[6] = UInt8(data3 & 0xFF)
            uuidBytes[7] = UInt8((data3 >> 8) & 0xFF)
            for i in 0..<8 { uuidBytes[8+i] = d4[i] }
            let u = UUID(uuid: (uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                                uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                                uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]))
            uuidStr = u.uuidString.lowercased()
        } else {
            uuidStr = String(format: "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                             data1, data2, data3, d4[0], d4[1], d4[2], d4[3], d4[4], d4[5], d4[6], d4[7])
        }

        return (urn, uuidStr)
    }

    func readObjectRef() -> UInt32? {
        return readU32()
    }

    func assertTag(_ expected: UInt8) -> Bool {
        guard let tag = readU8() else { return false }
        return tag == expected
    }

    func seek(to position: Int) {
        offset = position
    }

    func skip(_ count: Int) {
        offset += count
    }
}

// MARK: - Object Store

/// Intermediate representation of a parsed AVB object.
private class AvbObject {
    let classID: String
    let objectIndex: Int
    var properties: [String: Any] = [:]

    init(classID: String, objectIndex: Int) {
        self.classID = classID
        self.objectIndex = objectIndex
    }

    func string(_ key: String) -> String { properties[key] as? String ?? "" }
    func int(_ key: String) -> Int { properties[key] as? Int ?? 0 }
    func double(_ key: String) -> Double { properties[key] as? Double ?? 0 }
    func date(_ key: String) -> Date? { properties[key] as? Date }
    func ref(_ key: String) -> Int { properties[key] as? Int ?? 0 }
    func bool(_ key: String) -> Bool { properties[key] as? Bool ?? false }
}

// MARK: - Parser

/// Parses Avid .avb bin files and extracts clip metadata.
final class AvbParser {

    /// Parse a single .avb file at the given path.
    // MARK: - parse() decomposition

    /// Result of header parsing: either (reader positioned past header, info) or an error string.
    private struct AvbHeader {
        let reader: BinaryReader
        let creatorVersion: String
        let lastSave: Date?
        let numObjects: UInt32
        let rootIndex: UInt32
        let isLE: Bool
    }

    /// Parse and validate the .avb file header. Returns (header, nil) on success
    /// or (nil, errorMessage) on any validation failure.
    private static func parseHeader(fileData: Data) -> (AvbHeader?, String?) {
        // Detect byte order from first 2 bytes
        let orderBytes = [fileData[0], fileData[1]]
        let isLE: Bool
        if orderBytes == [0x06, 0x00] {
            isLE = true
        } else if orderBytes == [0x00, 0x06] {
            isLE = false
        } else {
            return (nil, "Not an AVB file (bad magic)")
        }

        let reader = BinaryReader(data: fileData, littleEndian: isLE)
        reader.skip(2) // byte order already read

        guard let magic = reader.readBytes(6),
              String(data: magic, encoding: .ascii) == "Domain" else {
            return (nil, "Not an AVB file (bad header)")
        }
        guard let headerCC = reader.readFourCC(), headerCC == "OBJD" else {
            return (nil, "Missing OBJD header")
        }
        guard let className = reader.readString(), className == "AObjDoc" else {
            return (nil, "Bad class name")
        }
        guard reader.assertTag(0x04) else {
            return (nil, "Bad version tag")
        }
        _ = reader.readString() ?? "" // lastSaveStr, unused

        guard let numObjects = reader.readU32(),
              let rootIndex = reader.readU32() else {
            return (nil, "Truncated header")
        }
        _ = reader.readU32()                // byte-order marker u32
        let lastSave = reader.readDateTime()
        reader.skip(4)                      // reserved

        guard reader.readFourCC() == "ATob", reader.readFourCC() == "ATve" else {
            return (nil, "Missing ATob/ATve")
        }
        guard let verLen = reader.readU16() else {
            return (nil, "Truncated version")
        }
        let verData = reader.readBytes(Int(verLen)) ?? Data()
        let creatorVersion = String(data: verData.filter { $0 != 0x20 && $0 != 0 },
                                    encoding: .macOSRoman) ?? ""
        let padNeeded = 32 - 2 - Int(verLen)
        if padNeeded > 0 { reader.skip(padNeeded) }
        reader.skip(16) // reserved

        return (AvbHeader(reader: reader,
                          creatorVersion: creatorVersion,
                          lastSave: lastSave,
                          numObjects: numObjects,
                          rootIndex: rootIndex,
                          isLE: isLE),
                nil)
    }

    /// Build the object-position lookup table by walking past each object's
    /// class_id (4) + size (4) + size bytes of payload.
    private static func buildObjectPositions(reader: BinaryReader, numObjects: UInt32) -> [Int] {
        var positions: [Int] = [0] // index 0 = root chunk (not a real object)
        for _ in 0..<numObjects {
            positions.append(reader.offset)
            reader.skip(4) // class_id
            guard let size = reader.readU32() else { break }
            reader.skip(Int(size))
        }
        return positions
    }

    /// For a MasterMob, chase each SourceClip track to the matching SourceMob
    /// and fill in any missing media-path / descriptor-type / tape-name fields.
    /// State flows through inout parameters — this is exactly what the original
    /// nested loop did, just isolated for readability and testability.
    private static func chaseMasterMobDescriptors(
        mobObj: AvbObject,
        objectPositions: [Int],
        readObj: (Int) -> AvbObject?,
        mediaPath: inout String,
        mediaPathPosix: inout String,
        descriptorType: inout String,
        tapeName: inout String
    ) {
        let trackRefs = mobObj.properties["track_component_refs"]
            as? [(index: Int, componentRef: Int)] ?? []
        for (_, compRef) in trackRefs {
            guard compRef > 0,
                  let compObj = readObj(compRef),
                  compObj.classID == "SCLP" else { continue }
            let srcMobIDUrn = compObj.string("mob_id_urn")
            guard !srcMobIDUrn.isEmpty else { continue }

            for idx in 1..<objectPositions.count {
                guard let candidate = readObj(idx),
                      candidate.classID == "CMPO",
                      candidate.string("mob_id_urn") == srcMobIDUrn else { continue }

                let dRef = candidate.ref("descriptor_ref")
                if dRef > 0, let dObj = readObj(dRef) {
                    if mediaPath.isEmpty {
                        let lRef = dObj.ref("locator_ref")
                        if lRef > 0, let lObj = readObj(lRef) {
                            mediaPath = lObj.string("path")
                            mediaPathPosix = lObj.string("path_posix")
                        }
                    }
                    if descriptorType.isEmpty || descriptorType == "MDES" {
                        descriptorType = dObj.classID
                    }
                    if tapeName.isEmpty && dObj.classID == "MDTP" {
                        tapeName = candidate.string("name")
                    }
                }
                break
            }
        }
    }

    private static func mobTypeLabel(_ id: Int) -> String {
        switch id {
        case 1: return "CompositionMob"
        case 2: return "MasterMob"
        case 3: return "SourceMob"
        default: return "Unknown(\(id))"
        }
    }

    private static func mediaKindLabel(_ id: Int) -> String {
        switch id {
        case 1: return "picture"
        case 2: return "sound"
        case 3: return "timecode"
        case 4: return "edgecode"
        case 5: return "data"
        default: return "unknown(\(id))"
        }
    }

    /// Build the list of tracks for a mob by walking its track_component_refs.
    private static func buildTracks(mobObj: AvbObject,
                                    readObj: (Int) -> AvbObject?) -> [AvbTrack] {
        var tracks: [AvbTrack] = []
        let trackRefs = mobObj.properties["track_component_refs"]
            as? [(index: Int, componentRef: Int)] ?? []
        for (trackIdx, compRef) in trackRefs {
            guard compRef > 0, let compObj = readObj(compRef) else { continue }
            tracks.append(AvbTrack(
                index: trackIdx,
                mediaKind: mediaKindLabel(compObj.int("media_kind_id")),
                startPos: compObj.int("start_pos"),
                length: compObj.int("length"),
                sourceClipMobID: compObj.classID == "SCLP" ? compObj.string("mob_id_urn") : "",
                sourceTrackID: compObj.int("track_id")
            ))
        }
        return tracks
    }

    /// Assemble a single AvbClip from a CMPO object.
    private static func extractClip(
        from mobObj: AvbObject,
        objectPositions: [Int],
        readObj: (Int) -> AvbObject?,
        binFileName: String
    ) -> AvbClip {
        let mobTypeID = mobObj.int("mob_type_id")

        // Chase the direct descriptor (applies to SourceMobs)
        var mediaPath = ""
        var mediaPathPosix = ""
        var tapeName = ""
        var descriptorType = ""

        let descRef = mobObj.ref("descriptor_ref")
        if descRef > 0, let descObj = readObj(descRef) {
            descriptorType = descObj.classID
            let locRef = descObj.ref("locator_ref")
            if locRef > 0, let locObj = readObj(locRef) {
                mediaPath = locObj.string("path")
                mediaPathPosix = locObj.string("path_posix")
            }
            if descObj.classID == "MDTP" {
                tapeName = mobObj.string("name")
            }
        }

        // MasterMobs don't own a descriptor directly — chase SourceClip tracks.
        if mobTypeID == 2 {
            chaseMasterMobDescriptors(
                mobObj: mobObj,
                objectPositions: objectPositions,
                readObj: readObj,
                mediaPath: &mediaPath,
                mediaPathPosix: &mediaPathPosix,
                descriptorType: &descriptorType,
                tapeName: &tapeName
            )
        }

        return AvbClip(
            clipName: mobObj.string("name"),
            mobType: mobTypeLabel(mobTypeID),
            mobID: mobObj.string("mob_id_urn"),
            materialUUID: mobObj.string("material_uuid"),
            tapeName: tapeName,
            creationDate: mobObj.date("creation_time"),
            lastModified: mobObj.date("last_modified"),
            editRate: mobObj.double("edit_rate"),
            duration: mobObj.int("length"),
            tracks: buildTracks(mobObj: mobObj, readObj: readObj),
            mediaPath: mediaPath,
            mediaPathPosix: mediaPathPosix,
            descriptorType: descriptorType,
            binFileName: binFileName
        )
    }

    // MARK: - parse()

    static func parse(fileAt path: String) -> AvbBinResult {
        let url = URL(fileURLWithPath: path)
        let binName = url.deletingPathExtension().lastPathComponent

        func fail(_ message: String, creatorVersion: String = "", lastSave: Date? = nil) -> AvbBinResult {
            AvbBinResult(filePath: path, binName: binName, creatorVersion: creatorVersion,
                         lastSave: lastSave, clips: [], errors: [message])
        }

        guard let fileData = try? Data(contentsOf: url) else { return fail("Cannot read file") }
        guard fileData.count >= 8 else { return fail("File too small") }

        let (headerOpt, headerErr) = parseHeader(fileData: fileData)
        guard let header = headerOpt else {
            return fail(headerErr ?? "Header parse failed")
        }

        let reader = header.reader
        let isLE = header.isLE
        let objectPositions = buildObjectPositions(reader: reader, numObjects: header.numObjects)

        // Parse objects on demand from the position table.
        var objectCache: [Int: AvbObject] = [:]
        func readObject(at index: Int) -> AvbObject? {
            guard index > 0, index < objectPositions.count else { return nil }
            if let cached = objectCache[index] { return cached }

            reader.seek(to: objectPositions[index])

            guard let rawCC = reader.readBytes(4) else { return nil }
            let classID: String
            if isLE {
                classID = String(bytes: [rawCC[3], rawCC[2], rawCC[1], rawCC[0]], encoding: .ascii) ?? "????"
            } else {
                classID = String(data: rawCC, encoding: .ascii) ?? "????"
            }

            guard let size = reader.readU32() else { return nil }
            let dataEnd = reader.offset + Int(size)

            let obj = AvbObject(classID: classID, objectIndex: index)
            switch classID {
            case "ABIN", "BINF": parseBin(reader: reader, obj: obj, isLE: isLE, readObj: readObject)
            case "CMPO":         parseComposition(reader: reader, obj: obj, readObj: readObject)
            case "MDES":         parseMediaDescriptor(reader: reader, obj: obj, readObj: readObject)
            case "MDFL":         parseMediaFileDescriptor(reader: reader, obj: obj, readObj: readObject)
            case "MDTP":         parseTapeDescriptor(reader: reader, obj: obj, readObj: readObject)
            case "FILE", "WINF": parseFileLocator(reader: reader, obj: obj)
            case "SCLP":         parseSourceClip(reader: reader, obj: obj)
            case "TRKG":         parseTrackGroup(reader: reader, obj: obj, readObj: readObject)
            default:             break
            }

            reader.seek(to: dataEnd)
            objectCache[index] = obj
            return obj
        }

        guard let rootObj = readObject(at: Int(header.rootIndex)) else {
            return fail("Failed to read root bin object",
                        creatorVersion: header.creatorVersion, lastSave: header.lastSave)
        }

        var clips: [AvbClip] = []
        let itemRefs = rootObj.properties["item_refs"] as? [Int] ?? []
        for mobRef in itemRefs {
            guard let mobObj = readObject(at: mobRef), mobObj.classID == "CMPO" else { continue }
            clips.append(extractClip(from: mobObj,
                                     objectPositions: objectPositions,
                                     readObj: readObject,
                                     binFileName: url.lastPathComponent))
        }

        return AvbBinResult(filePath: path, binName: binName,
                            creatorVersion: header.creatorVersion, lastSave: header.lastSave,
                            clips: clips, errors: [])
    }

    /// Scan a directory recursively for .avb files and parse all of them.
    static func scanDirectory(_ dirPath: String) -> [AvbBinResult] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: dirPath)
        var results: [AvbBinResult] = []

        guard let enumerator = fm.enumerator(at: url,
                                              includingPropertiesForKeys: [.isRegularFileKey],
                                              options: [.skipsHiddenFiles]) else {
            return results
        }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "avb" {
                results.append(parse(fileAt: fileURL.path))
            }
        }

        return results
    }

    // MARK: - Object Parsers

    /// Parse ABIN / BINF — the top-level bin container.
    private static func parseBin(reader: BinaryReader, obj: AvbObject, isLE: Bool,
                                  readObj: (Int) -> AvbObject?) {
        // Component base: 0x02, 0x03
        // ... we skip component fields for the bin itself
        // The bin read sequence from pyavb:
        //   tag 0x02, version (0x0e or 0x0f)
        //   view_setting ref, uid u64
        //   object_count (u16 or u32 for large bins)
        //   for each item: mob_ref, x, y, keyframe, user_placed

        guard reader.assertTag(0x02) else { return }
        guard let version = reader.readU8(), version == 0x0e || version == 0x0f else { return }

        let _viewSettingRef = reader.readObjectRef() // skip
        _ = _viewSettingRef
        let _uid = reader.readU64() // skip
        _ = _uid

        let objectCount: Int
        if version == 0x0e {
            objectCount = Int(reader.readU16() ?? 0)
        } else {
            objectCount = Int(reader.readU32() ?? 0)
        }

        var itemRefs: [Int] = []
        for _ in 0..<objectCount {
            let mobRef = Int(reader.readObjectRef() ?? 0)
            _ = reader.readS16() // x
            _ = reader.readS16() // y
            _ = reader.readS32() // keyframe
            _ = reader.readBool() // user_placed
            if mobRef > 0 {
                itemRefs.append(mobRef)
            }
        }
        obj.properties["item_refs"] = itemRefs
    }

    /// Parse CMPO — Composition (mob). Contains the clip name, MobID, tracks.
    private static func parseComposition(reader: BinaryReader, obj: AvbObject,
                                          readObj: (Int) -> AvbObject?) {
        // Component base reads
        guard reader.assertTag(0x02), reader.assertTag(0x03) else { return }

        // left_bob, right_bob (object refs — skip)
        _ = reader.readObjectRef()
        _ = reader.readObjectRef()

        let mediaKindID = Int(reader.readS16() ?? 0)
        obj.properties["media_kind_id"] = mediaKindID

        let editRate = reader.readExp10Float() ?? 25.0
        obj.properties["edit_rate"] = editRate

        let name = reader.readString() ?? ""
        obj.properties["name"] = name

        let effectID = reader.readString() // skip
        _ = effectID

        let attrsRef = reader.readObjectRef() // skip
        _ = attrsRef
        let sessionRef = reader.readObjectRef() // skip
        _ = sessionRef
        let precompRef = reader.readObjectRef() // skip
        _ = precompRef

        // Skip component ext tags
        skipExtTags(reader: reader)

        // TrackGroup base: 0x02, 0x08
        guard reader.assertTag(0x02), reader.assertTag(0x08) else { return }

        let mcMode = reader.readU8()
        _ = mcMode
        let length = Int(reader.readS32() ?? 0)
        obj.properties["length"] = length
        let numScalars = reader.readS32()
        _ = numScalars

        let trackCount = Int(reader.readS32() ?? 0)
        var trackComponentRefs: [(index: Int, componentRef: Int)] = []

        for _ in 0..<trackCount {
            guard let flags = reader.readU16() else { break }
            var trackIndex = 0
            var componentRef = 0

            if flags & 0x0001 != 0 { trackIndex = Int(reader.readS16() ?? 0) }          // LABEL
            if flags & 0x0002 != 0 { _ = reader.readObjectRef() }                       // ATTRIBUTES
            if flags & 0x0200 != 0 { _ = reader.readObjectRef() }                       // SESSION_ATTR
            if flags & 0x0004 != 0 { componentRef = Int(reader.readObjectRef() ?? 0) }  // COMPONENT
            if flags & 0x0008 != 0 { _ = reader.readObjectRef() }                       // FILLER_PROXY
            if flags & 0x0010 != 0 { _ = reader.readObjectRef() }                       // BOB_DATA
            if flags & 0x0020 != 0 { _ = reader.readS16() }                             // CONTROL_CODE
            if flags & 0x0040 != 0 { _ = reader.readS16() }                             // CONTROL_SUB_CODE
            if flags & 0x0080 != 0 { _ = reader.readS32() }                             // START_POS
            if flags & 0x0100 != 0 { _ = reader.readBool() }                            // READ_ONLY

            trackComponentRefs.append((index: trackIndex, componentRef: componentRef))
        }
        obj.properties["track_component_refs"] = trackComponentRefs

        // Skip TrackGroup ext tags (lock numbers etc)
        skipExtTags(reader: reader)

        // Composition-specific: 0x02, version
        guard reader.assertTag(0x02) else { return }
        guard let compVersion = reader.readU8() else { return }

        // mob_id_lo, mob_id_hi (legacy 32-bit pair, used for quick lookup)
        _ = reader.readU32()
        _ = reader.readU32()

        let usageCode = reader.readU8()
        _ = usageCode

        let mobTypeID = Int(reader.readU8() ?? 2)
        obj.properties["mob_type_id"] = mobTypeID

        let creationTime = reader.readDateTime()
        obj.properties["creation_time"] = creationTime

        let lastModified = reader.readDateTime()
        obj.properties["last_modified"] = lastModified

        // Descriptor ref (for SourceMobs)
        if compVersion >= 0x03 {
            // Some versions have descriptor ref in ext tags
        }

        // Extended tags for Composition
        // Read ext tags looking for mob_id and descriptor
        while true {
            let pos = reader.offset
            guard let tag = reader.readU8() else { break }
            if tag != 0x01 {
                reader.seek(to: pos)
                break
            }
            guard let extTag = reader.readU8() else { break }

            switch extTag {
            case 0x01:
                // MobID
                if let mobIDResult = reader.readMobID() {
                    obj.properties["mob_id_urn"] = mobIDResult.urn
                    obj.properties["material_uuid"] = mobIDResult.materialUUID
                }
            case 0x02:
                // Descriptor reference
                guard reader.assertTag(72) else { break }
                let descRef = Int(reader.readObjectRef() ?? 0)
                obj.properties["descriptor_ref"] = descRef
            case 0x03:
                // Usage code string
                guard reader.assertTag(72) else { break }
                _ = reader.readObjectRef()
            default:
                break
            }
        }
    }

    /// Parse SCLP — Source Clip (references another mob by MobID).
    private static func parseSourceClip(reader: BinaryReader, obj: AvbObject) {
        // Component base
        guard reader.assertTag(0x02), reader.assertTag(0x03) else { return }
        _ = reader.readObjectRef() // left_bob
        _ = reader.readObjectRef() // right_bob
        obj.properties["media_kind_id"] = Int(reader.readS16() ?? 0)
        obj.properties["edit_rate"] = reader.readExp10Float() ?? 25.0
        _ = reader.readString() // name
        _ = reader.readString() // effect_id
        _ = reader.readObjectRef() // attributes
        _ = reader.readObjectRef() // session_attrs
        _ = reader.readObjectRef() // precomputed
        skipExtTags(reader: reader)

        // Clip base: 0x02, 0x01
        guard reader.assertTag(0x02), reader.assertTag(0x01) else { return }
        obj.properties["length"] = Int(reader.readS32() ?? 0)

        // SourceClip: 0x02, 0x03
        guard reader.assertTag(0x02), reader.assertTag(0x03) else { return }
        _ = reader.readU32() // mob_id_hi
        _ = reader.readU32() // mob_id_lo
        obj.properties["track_id"] = Int(reader.readS16() ?? 0)
        obj.properties["start_pos"] = Int(reader.readS32() ?? 0)

        // Ext tags — look for full MobID
        while true {
            let pos = reader.offset
            guard let tag = reader.readU8() else { break }
            if tag != 0x01 { reader.seek(to: pos); break }
            guard let extTag = reader.readU8() else { break }
            if extTag == 0x01 {
                if let mobIDResult = reader.readMobID() {
                    obj.properties["mob_id_urn"] = mobIDResult.urn
                    obj.properties["material_uuid"] = mobIDResult.materialUUID
                }
            }
        }
    }

    /// Parse MDES — Media Descriptor base.
    private static func parseMediaDescriptor(reader: BinaryReader, obj: AvbObject,
                                              readObj: (Int) -> AvbObject?) {
        guard reader.assertTag(0x02), reader.assertTag(0x03) else { return }
        _ = reader.readU8() // mob_kind
        let locRef = Int(reader.readObjectRef() ?? 0)
        obj.properties["locator_ref"] = locRef
        _ = reader.readBool() // intermediate
        _ = reader.readObjectRef() // physical_media

        skipExtTags(reader: reader)
    }

    /// Parse MDFL — Media File Descriptor (extends MDES).
    private static func parseMediaFileDescriptor(reader: BinaryReader, obj: AvbObject,
                                                   readObj: (Int) -> AvbObject?) {
        // MDES base
        parseMediaDescriptor(reader: reader, obj: obj, readObj: readObj)

        guard reader.assertTag(0x02), reader.assertTag(0x03) else { return }
        obj.properties["edit_rate"] = reader.readExp10Float() ?? 25.0
        obj.properties["length"] = Int(reader.readS32() ?? 0)
        _ = reader.readS16() // is_omfi
        _ = reader.readS32() // data_offset
    }

    /// Parse MDTP — Tape Descriptor (extends MDES).
    private static func parseTapeDescriptor(reader: BinaryReader, obj: AvbObject,
                                             readObj: (Int) -> AvbObject?) {
        parseMediaDescriptor(reader: reader, obj: obj, readObj: readObj)

        guard reader.assertTag(0x02), reader.assertTag(0x02) else { return }
        _ = reader.readS16() // cframe
    }

    /// Parse FILE / WINF — File Locator (contains the media file path).
    private static func parseFileLocator(reader: BinaryReader, obj: AvbObject) {
        guard reader.assertTag(0x02), reader.assertTag(0x02) else { return }

        obj.properties["path"] = reader.readString() ?? ""

        // Ext tags for posix and utf-8 paths
        while true {
            let pos = reader.offset
            guard let tag = reader.readU8() else { break }
            if tag != 0x01 { reader.seek(to: pos); break }
            guard let extTag = reader.readU8() else { break }

            switch extTag {
            case 0x01:
                guard reader.assertTag(76) else { break }
                obj.properties["path_posix"] = reader.readString() ?? ""
            case 0x02:
                guard reader.assertTag(76) else { break }
                obj.properties["path_utf8"] = reader.readString(encoding: .utf8) ?? ""
            case 0x03:
                guard reader.assertTag(76) else { break }
                obj.properties["path2_utf8"] = reader.readString(encoding: .utf8) ?? ""
            default:
                break
            }
        }
    }

    /// Parse TRKG — Track Group (used as base for various group types).
    private static func parseTrackGroup(reader: BinaryReader, obj: AvbObject,
                                         readObj: (Int) -> AvbObject?) {
        // Component base
        guard reader.assertTag(0x02), reader.assertTag(0x03) else { return }
        _ = reader.readObjectRef() // left_bob
        _ = reader.readObjectRef() // right_bob
        obj.properties["media_kind_id"] = Int(reader.readS16() ?? 0)
        obj.properties["edit_rate"] = reader.readExp10Float() ?? 25.0
        _ = reader.readString() // name
        _ = reader.readString() // effect_id
        _ = reader.readObjectRef() // attributes
        _ = reader.readObjectRef() // session_attrs
        _ = reader.readObjectRef() // precomputed
        skipExtTags(reader: reader)

        // TrackGroup: 0x02, 0x08
        guard reader.assertTag(0x02), reader.assertTag(0x08) else { return }
        _ = reader.readU8() // mc_mode
        obj.properties["length"] = Int(reader.readS32() ?? 0)
        _ = reader.readS32() // num_scalars

        let trackCount = Int(reader.readS32() ?? 0)
        var trackComponentRefs: [(index: Int, componentRef: Int)] = []
        for _ in 0..<trackCount {
            guard let flags = reader.readU16() else { break }
            var trackIndex = 0
            var componentRef = 0
            if flags & 0x0001 != 0 { trackIndex = Int(reader.readS16() ?? 0) }
            if flags & 0x0002 != 0 { _ = reader.readObjectRef() }
            if flags & 0x0200 != 0 { _ = reader.readObjectRef() }
            if flags & 0x0004 != 0 { componentRef = Int(reader.readObjectRef() ?? 0) }
            if flags & 0x0008 != 0 { _ = reader.readObjectRef() }
            if flags & 0x0010 != 0 { _ = reader.readObjectRef() }
            if flags & 0x0020 != 0 { _ = reader.readS16() }
            if flags & 0x0040 != 0 { _ = reader.readS16() }
            if flags & 0x0080 != 0 { _ = reader.readS32() }
            if flags & 0x0100 != 0 { _ = reader.readBool() }
            trackComponentRefs.append((index: trackIndex, componentRef: componentRef))
        }
        obj.properties["track_component_refs"] = trackComponentRefs
    }

    /// Skip a sequence of extension tags (0x01 + tag + data).
    /// Used to skip over optional fields we don't need.
    private static func skipExtTags(reader: BinaryReader) {
        while true {
            let pos = reader.offset
            guard let tag = reader.readU8() else { return }
            if tag != 0x01 {
                reader.seek(to: pos)
                return
            }
            // Read the ext tag ID and skip its data
            // This is tricky because ext tag data has variable length.
            // We just skip the sub-tag and try to consume one value.
            guard let extTag = reader.readU8() else { return }
            _ = extTag

            // Try to consume the value after the ext tag
            let valPos = reader.offset
            guard let valTag = reader.readU8() else { return }
            switch valTag {
            case 65: // byte array: s32 length + data
                guard let len = reader.readS32() else { return }
                reader.skip(Int(len))
            case 68: // single byte
                _ = reader.readU8()
            case 69: // s16
                _ = reader.readS16()
            case 70: // u16
                _ = reader.readU16()
            case 71: // s32
                _ = reader.readS32()
            case 72: // object ref (u32)
                _ = reader.readObjectRef()
            case 73: // s64
                _ = reader.readU64()
            case 76: // string
                _ = reader.readString()
            default:
                // Unknown value tag — back up and stop
                reader.seek(to: valPos)
                return
            }
        }
    }
}
