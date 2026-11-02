// WritePermit.swift
// THE write primitive for anything that must stop writing the moment an
// authority is revoked (the app's Family Tree read-only state, codex #190 →
// #193). Three Codex passes each found another "check, then wait, then write":
// a check taken before a lock, before an await, or into a captured Bool. The
// fix is structural: a writer performs its bytes ONLY inside `withWrite`,
// placed AFTER every lock and await, and `withWrite` re-asks the authority at
// that moment.
//
// The caller's authority reaches nested Core writers (CyberBrainWriter under
// its root lock, the overlay store, the compiled store) through a task-local
// (`WritePermit.current`), bound by the app around the call — so a writer
// that waited for a lock asks the LIVE authority after the wait, without a
// permit parameter threaded through every API. Unbound = `.always` (CLIs,
// tests): behaviour unchanged.
//
// (C++: a thread-local "may I write?" functor, consulted inside the critical
// section right before the syscalls; `withWrite` ≈ `if (!permit()) throw;
// body();`.)

import Foundation

public struct WritePermit: Sendable {
    /// Asked at each write with what is about to be written; false refuses.
    /// The permit logs its own refusal (one line).
    public let mayWrite: @Sendable (String) -> Bool

    public init(_ mayWrite: @escaping @Sendable (String) -> Bool) { self.mayWrite = mayWrite }

    public static let always = WritePermit { _ in true }

    /// The permit bound by the caller for the writes nested inside its call.
    @TaskLocal public static var current: WritePermit = .always

    public struct Refused: Error, LocalizedError, Equatable {
        public let what: String
        public init(what: String) { self.what = what }
        public var errorDescription: String? { "Refused: \(what) — writing is not allowed now." }
    }

    /// Re-ask the authority NOW, then perform `body` — the bytes. Place it
    /// after every lock or await, around the writes themselves.
    public func withWrite<T>(_ what: String, _ body: () throws -> T) throws -> T {
        guard mayWrite(what) else { throw Refused(what: what) }
        return try body()
    }

    /// The same check against the bound `current` permit AND `self` (both
    /// must allow): for a writer that carries its own guard as well.
    public func and(_ other: WritePermit) -> WritePermit {
        WritePermit { what in self.mayWrite(what) && other.mayWrite(what) }
    }
}
