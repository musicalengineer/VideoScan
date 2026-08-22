import Foundation
import KokoroSwift
import MLXUtilsLibrary

private struct Arguments {
    var modelPath = ""
    var voicesPath = ""
    var outputDirectory = ""
    var voiceNames = ["af_heart"]
    var speed: Float = 0.92
    var text = "Hello from Hallie."

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let option = raw[index]
            guard index + 1 < raw.count else {
                throw UsageError("Missing value for \(option)")
            }
            let value = raw[index + 1]
            switch option {
            case "--model": modelPath = value
            case "--voices": voicesPath = value
            case "--output": outputDirectory = value
            case "--voice": voiceNames = value.split(separator: ",").map(String.init)
            case "--speed":
                guard let parsed = Float(value), parsed > 0 else {
                    throw UsageError("Invalid speed: \(value)")
                }
                speed = parsed
            case "--text": text = value
            default: throw UsageError("Unknown option: \(option)")
            }
            index += 2
        }

        guard !modelPath.isEmpty, !voicesPath.isEmpty, !outputDirectory.isEmpty else {
            throw UsageError("--model, --voices, and --output are required")
        }
    }
}

private struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}

private func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
    let pcm: [Int16] = samples.map { sample in
        let clamped = max(-1, min(1, sample))
        return Int16(clamped * Float(Int16.max))
    }
    let dataByteCount = pcm.count * MemoryLayout<Int16>.size
    var output = Data()
    output.append(Data("RIFF".utf8))
    appendLittleEndian(UInt32(36 + dataByteCount), to: &output)
    output.append(Data("WAVEfmt ".utf8))
    appendLittleEndian(UInt32(16), to: &output)
    appendLittleEndian(UInt16(1), to: &output)
    appendLittleEndian(UInt16(1), to: &output)
    appendLittleEndian(UInt32(sampleRate), to: &output)
    appendLittleEndian(UInt32(sampleRate * MemoryLayout<Int16>.size), to: &output)
    appendLittleEndian(UInt16(MemoryLayout<Int16>.size), to: &output)
    appendLittleEndian(UInt16(16), to: &output)
    output.append(Data("data".utf8))
    appendLittleEndian(UInt32(dataByteCount), to: &output)
    for sample in pcm { appendLittleEndian(sample, to: &output) }
    try output.write(to: url, options: .atomic)
}

@main
private enum HallieKokoroHelper {
    static func main() throws {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            let modelURL = URL(fileURLWithPath: arguments.modelPath)
            let voicesURL = URL(fileURLWithPath: arguments.voicesPath)
            let outputURL = URL(fileURLWithPath: arguments.outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            let engine = KokoroTTS(modelPath: modelURL)
            guard let voices = NpyzReader.read(fileFromPath: voicesURL) else {
                throw UsageError("Could not load voice embeddings at \(voicesURL.path)")
            }

            for voiceName in arguments.voiceNames {
                guard let voice = voices[voiceName + ".npy"] else {
                    throw UsageError("Voice is not installed: \(voiceName)")
                }
                let (audio, _) = try engine.generateAudio(
                    voice: voice,
                    language: voiceName.first == "b" ? .enGB : .enUS,
                    text: arguments.text,
                    speed: arguments.speed
                )
                let fileURL = outputURL.appendingPathComponent("hallie-\(voiceName).wav")
                try writeWAV(audio, sampleRate: KokoroTTS.Constants.samplingRate, to: fileURL)
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            let usage = "usage: kokoro-tts --model FILE --voices FILE --output DIR "
                + "[--voice NAME] [--speed 0.92] [--text TEXT]\n"
            FileHandle.standardError.write(Data(usage.utf8))
            Foundation.exit(2)
        }
    }
}
