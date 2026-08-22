// HallieTerminalLineEditor.swift
// Minimal interactive editing for the standalone Hallie shell.

import Darwin
import Foundation

struct HallieLineEditor {
    enum Key: Equatable {
        case character(Character)
        case enter
        case endOfFile
        case cancelLine
        case backspace
        case left
        case right
        case historyPrevious
        case historyNext
        case moveToStart
        case moveToEnd
        case ignored
    }

    enum Outcome: Equatable {
        case continueEditing
        case submit(String)
        case endOfFile
        case cancelLine
    }

    private(set) var characters: [Character] = []
    private(set) var cursor = 0
    private(set) var history: [String] = []
    private var historyIndex: Int?
    private var draft: [Character] = []

    var text: String { String(characters) }

    mutating func beginLine() {
        characters.removeAll(keepingCapacity: true)
        cursor = 0
        historyIndex = nil
        draft.removeAll(keepingCapacity: true)
    }

    mutating func handle(_ key: Key) -> Outcome {
        switch key {
        case .character(let character):
            characters.insert(character, at: cursor)
            cursor += 1
        case .enter:
            let submitted = text
            if !submitted.isEmpty, history.last != submitted {
                history.append(submitted)
                if history.count > 100 {
                    history.removeFirst(history.count - 100)
                }
            }
            return .submit(submitted)
        case .endOfFile:
            return endOfFileOutcome()
        case .cancelLine:
            return .cancelLine
        case .backspace:
            if cursor > 0 {
                characters.remove(at: cursor - 1)
                cursor -= 1
            }
        case .left:
            cursor = max(0, cursor - 1)
        case .right:
            cursor = min(characters.count, cursor + 1)
        case .historyPrevious:
            recallPrevious()
        case .historyNext:
            recallNext()
        case .moveToStart:
            cursor = 0
        case .moveToEnd:
            cursor = characters.count
        case .ignored:
            break
        }
        return .continueEditing
    }

    private func endOfFileOutcome() -> Outcome {
        characters.isEmpty ? .endOfFile : .continueEditing
    }

    private mutating func recallPrevious() {
        guard !history.isEmpty else { return }
        if let historyIndex {
            self.historyIndex = max(0, historyIndex - 1)
        } else {
            draft = characters
            historyIndex = history.count - 1
        }
        guard let historyIndex else { return }
        characters = Array(history[historyIndex])
        cursor = characters.count
    }

    private mutating func recallNext() {
        guard let historyIndex else { return }
        if historyIndex < history.count - 1 {
            self.historyIndex = historyIndex + 1
            characters = Array(history[historyIndex + 1])
        } else {
            self.historyIndex = nil
            characters = draft
        }
        cursor = characters.count
    }
}

enum HallieTerminalKeyDecoder {
    static func decode(_ bytes: [UInt8]) -> HallieLineEditor.Key {
        switch bytes {
        case [0x01]: return .moveToStart       // Ctrl-A
        case [0x03]: return .cancelLine        // Ctrl-C
        case [0x04]: return .endOfFile         // Ctrl-D
        case [0x05]: return .moveToEnd         // Ctrl-E
        case [0x08], [0x7f]: return .backspace
        case [0x0a], [0x0d]: return .enter
        case [0x1b, 0x5b, 0x41]: return .historyPrevious
        case [0x1b, 0x5b, 0x42]: return .historyNext
        case [0x1b, 0x5b, 0x43]: return .right
        case [0x1b, 0x5b, 0x44]: return .left
        default:
            guard bytes.first != 0x1b,
                  let string = String(bytes: bytes, encoding: .utf8),
                  string.count == 1,
                  let character = string.first,
                  !character.isASCII || character.asciiValue.map({ $0 >= 0x20 }) == true
            else { return .ignored }
            return .character(character)
        }
    }
}

struct HallieTerminalLineReader {
    private var editor = HallieLineEditor()

    mutating func readLine(prompt: String) -> String? {
        editor.beginLine()
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            print(prompt)
            fflush(stdout)
            return Swift.readLine()
        }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            print(prompt)
            fflush(stdout)
            return Swift.readLine()
        }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | IEXTEN | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { controlCharacters in
            controlCharacters[Int(VMIN)] = 1
            controlCharacters[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            print(prompt)
            fflush(stdout)
            return Swift.readLine()
        }
        defer { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }

        writeToTerminal(prompt)
        while true {
            guard let key = readKey() else {
                writeToTerminal("\r\n")
                return nil
            }
            switch editor.handle(key) {
            case .continueEditing:
                redraw(prompt: prompt)
            case .submit(let line):
                writeToTerminal("\r\n")
                return line
            case .endOfFile:
                writeToTerminal("\r\n")
                return nil
            case .cancelLine:
                writeToTerminal("^C\r\n")
                return ""
            }
        }
    }

    private func readKey() -> HallieLineEditor.Key? {
        guard let first = readByte() else { return nil }
        if first == 0x1b {
            guard let second = readByte(), let third = readByte() else {
                return .ignored
            }
            return HallieTerminalKeyDecoder.decode([first, second, third])
        }
        if first < 0x80 {
            return HallieTerminalKeyDecoder.decode([first])
        }

        let length: Int
        switch first {
        case 0xc2...0xdf: length = 2
        case 0xe0...0xef: length = 3
        case 0xf0...0xf4: length = 4
        default: return .ignored
        }
        var bytes = [first]
        for _ in 1..<length {
            guard let byte = readByte() else { return .ignored }
            bytes.append(byte)
        }
        return HallieTerminalKeyDecoder.decode(bytes)
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        return count == 1 ? byte : nil
    }

    private func redraw(prompt: String) {
        var rendered = "\r\(prompt)\(editor.text)\u{001b}[K"
        let trailingCharacters = editor.characters.count - editor.cursor
        if trailingCharacters > 0 {
            rendered += "\u{001b}[\(trailingCharacters)D"
        }
        writeToTerminal(rendered)
    }

    private func writeToTerminal(_ string: String) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            _ = Darwin.write(STDOUT_FILENO, baseAddress, buffer.count)
        }
    }
}
