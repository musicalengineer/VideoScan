// CatalogPreflightReaderQAR2Tests.swift
// QA round 2: the SQLite fact behind the lost-cancel finding. GREEN on
// purpose — it documents that an interrupt with no statement running is dropped.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

extension CatalogPreflightReaderTests {
    @Test func qaR2_interruptWithNoStatementRunningIsDropped() throws {
        let queue = try DatabaseQueue()
        try queue.write { try $0.execute(sql: "CREATE TABLE t (x)") }
        queue.interrupt()
        let lines = try queue.read { try String.fetchAll($0, sql: "PRAGMA quick_check") }
        #expect(lines == ["ok"], "the early interrupt was not remembered")
    }
}
