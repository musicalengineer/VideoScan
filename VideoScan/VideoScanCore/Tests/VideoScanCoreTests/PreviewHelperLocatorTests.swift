// PreviewHelperLocatorTests.swift
// Stage 2 — the helper-binary resolver. All four branches are exercised
// with temp dirs and injected inputs; no real bundle, no real .build tree.
// (Resolution order: env override → app bundle → dev .build → NotFound.)

import XCTest
@testable import VideoScanCore

final class PreviewHelperLocatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Create an EXECUTABLE stub file at `url` (chmod 0755).
    @discardableResult
    private func makeExecutable(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeNonExecutable(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        return url
    }

    func testEnvOverrideWins() throws {
        let exe = try makeExecutable(at: root.appendingPathComponent("custom/helper-bin"))
        let resolved = try PreviewHelperLocator.resolve(
            environment: [PreviewHelperLocator.envOverrideKey: exe.path],
            bundleURL: nil,
            devSearchRoots: [])
        XCTAssertEqual(resolved.path, exe.path)
    }

    func testEnvOverrideNonExecutableFallsThroughToBundle() throws {
        let notExe = try makeNonExecutable(at: root.appendingPathComponent("bad/helper"))
        let bundle = root.appendingPathComponent("App.app", isDirectory: true)
        let bundled = try makeExecutable(
            at: bundle.appendingPathComponent("Contents/Helpers/\(PreviewHelperLocator.helperName)"))
        let resolved = try PreviewHelperLocator.resolve(
            environment: [PreviewHelperLocator.envOverrideKey: notExe.path],
            bundleURL: bundle,
            devSearchRoots: [])
        XCTAssertEqual(resolved.path, bundled.path)
    }

    func testBundleHelpersDirFound() throws {
        let bundle = root.appendingPathComponent("App.app", isDirectory: true)
        let bundled = try makeExecutable(
            at: bundle.appendingPathComponent("Contents/Helpers/\(PreviewHelperLocator.helperName)"))
        let resolved = try PreviewHelperLocator.resolve(
            environment: [:], bundleURL: bundle, devSearchRoots: [])
        XCTAssertEqual(resolved.path, bundled.path)
    }

    func testBundleMacOSDirFoundWhenNoHelpersDir() throws {
        let bundle = root.appendingPathComponent("App.app", isDirectory: true)
        let bundled = try makeExecutable(
            at: bundle.appendingPathComponent("Contents/MacOS/\(PreviewHelperLocator.helperName)"))
        let resolved = try PreviewHelperLocator.resolve(
            environment: [:], bundleURL: bundle, devSearchRoots: [])
        XCTAssertEqual(resolved.path, bundled.path)
    }

    func testDevBuildFallback() throws {
        let devRoot = root.appendingPathComponent(".build/debug", isDirectory: true)
        let devBin = try makeExecutable(
            at: devRoot.appendingPathComponent(PreviewHelperLocator.helperName))
        let resolved = try PreviewHelperLocator.resolve(
            environment: [:], bundleURL: nil, devSearchRoots: [devRoot])
        XCTAssertEqual(resolved.path, devBin.path)
    }

    func testMissingEverywhereThrowsNotFoundWithSearchedPaths() {
        let bundle = root.appendingPathComponent("App.app", isDirectory: true)
        let devRoot = root.appendingPathComponent(".build/debug", isDirectory: true)
        XCTAssertThrowsError(try PreviewHelperLocator.resolve(
            environment: [:], bundleURL: bundle, devSearchRoots: [devRoot])) { error in
            guard let notFound = error as? PreviewHelperLocator.NotFound else {
                return XCTFail("expected NotFound, got \(error)")
            }
            // Reports the bundle + dev paths it looked at, for a clear log.
            XCTAssertTrue(notFound.searched.contains { $0.contains("Contents/Helpers") })
            XCTAssertTrue(notFound.searched.contains { $0.contains(".build/debug") })
        }
    }

    /// The real dev-root computation should at least point at a `.build`
    /// under a dir containing Package.swift (whether or not it's built).
    func testDefaultDevSearchRootsPointAtPackageBuild() {
        let roots = PreviewHelperLocator.defaultDevSearchRoots()
        // In this test target the package root is reachable via #filePath.
        XCTAssertFalse(roots.isEmpty, "package root should be reachable from the test source")
        XCTAssertTrue(roots.allSatisfy { $0.path.contains("/.build/") })
    }
}
