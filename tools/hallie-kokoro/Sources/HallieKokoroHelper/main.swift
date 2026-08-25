import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

private struct Arguments {
    var modelPath = ""
    var voicesPath = ""
    var outputDirectory = ""
    var voiceNames = ["af_heart"]
    var speed: Float = 0.92
    var text = "Hello from Hallie."
    var workerMode = false

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let option = raw[index]
            if option == "--worker" {
                workerMode = true
                index += 1
                continue
            }
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

        guard !modelPath.isEmpty, !voicesPath.isEmpty,
              workerMode || !outputDirectory.isEmpty else {
            throw UsageError("--model and --voices are required; --output is required outside worker mode")
        }
    }
}

private struct UsageError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct WorkerRequest: Decodable {
    let id: String
    let outputDirectory: String
    let voiceName: String
    let speed: Float
    let text: String
}

private struct WorkerResponse: Encodable {
    let id: String
    let ok: Bool
    let error: String?
}

private let responsePrefix = "@hallie-response@"

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

private func synthesize(
    engine: KokoroTTS,
    voices: [String: MLXArray],
    outputDirectory: String,
    voiceName: String,
    speed: Float,
    text: String
) throws {
    guard let voice = voices[voiceName + ".npy"] else {
        throw UsageError("Voice is not installed: \(voiceName)")
    }
    let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    let (audio, _) = try engine.generateAudio(
        voice: voice,
        language: voiceName.first == "b" ? .enGB : .enUS,
        text: text,
        speed: speed
    )
    try writeWAV(
        audio,
        sampleRate: KokoroTTS.Constants.samplingRate,
        to: outputURL.appendingPathComponent("hallie-\(voiceName).wav")
    )
}

private func writeResponse(_ response: WorkerResponse) {
    guard let data = try? JSONEncoder().encode(response) else { return }
    FileHandle.standardOutput.write(Data(responsePrefix.utf8))
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
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

            if arguments.workerMode {
                while let line = readLine() {
                    guard let data = line.data(using: .utf8),
                          let request = try? JSONDecoder().decode(WorkerRequest.self, from: data) else {
                        writeResponse(WorkerResponse(
                            id: "", ok: false, error: "invalid worker request"))
                        continue
                    }
                    do {
                        try synthesize(
                            engine: engine,
                            voices: voices,
                            outputDirectory: request.outputDirectory,
                            voiceName: request.voiceName,
                            speed: request.speed,
                            text: request.text)
                        writeResponse(WorkerResponse(id: request.id, ok: true, error: nil))
                    } catch {
                        writeResponse(WorkerResponse(
                            id: request.id, ok: false,
                            error: error.localizedDescription))
                    }
                }
                return
            }

            for voiceName in arguments.voiceNames {
                try synthesize(
                    engine: engine,
                    voices: voices,
                    outputDirectory: outputURL.path,
                    voiceName: voiceName,
                    speed: arguments.speed,
                    text: arguments.text)
            }
        } catch let error as UsageError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            let usage = "usage: kokoro-tts --model FILE --voices FILE "
                + "(--worker | --output DIR [--voice NAME] [--speed 0.92] [--text TEXT])\n"
            FileHandle.standardError.write(Data(usage.utf8))
            Foundation.exit(2)
        }
    }
}
