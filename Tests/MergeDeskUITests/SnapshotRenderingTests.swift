import AppKit
@testable import MergeDeskCore
import MergeDeskFixtures
@testable import MergeDeskUI
import SwiftUI
import XCTest

/// Renders the Merge tab and the Resolve sheet to PNGs for a visual check. Runs only when
/// `MERGEDESK_SNAPSHOT_DIR` is set (it's a look, not an assertion), e.g.
/// `MERGEDESK_SNAPSHOT_DIR=/tmp/shots swift test --filter SnapshotRenderingTests`.
@MainActor
final class SnapshotRenderingTests: XCTestCase {
    private static let directoryVariable = "MERGEDESK_SNAPSHOT_DIR"
    private static let size = CGSize(width: 900, height: 900)

    func testRenderMergeFlowAndResolveSheet() async throws {
        guard let output = ProcessInfo.processInfo.environment[Self.directoryVariable] else {
            throw XCTSkip("set \(Self.directoryVariable) to render snapshots")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mergedesk-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let git = ProcessGitClient(environmentOverrides: FixtureBuilder.isolatedEnvironment)
        let fixture = try await FixtureBuilder().build(.contentConflict, in: folder)
        _ = try await git.run(["switch", "--quiet", FixtureBranch.base], in: fixture.url)
        let model = isolatedRepositoryModel(fixture.url, support: folder.appendingPathComponent("support"), git: git)
        model.refresh()
        await model.waitForRefresh()
        let flow = model.mergeFlow!
        flow.into = FixtureBranch.target
        flow.from = FixtureBranch.source
        flow.fetchFirst = false
        await flow.waitForPreview()
        try render(MergeFlowView(flow: flow), to: output, name: "1-choose")
        await flow.merge()
        try render(MergeFlowView(flow: flow), to: output, name: "2-conflicts")
        await flow.openResolver("Sources/App.swift")
        try render(ResolveSheet(flow: flow), to: output, name: "3-resolve")
        flow.chooseForAll(.from)
        try render(ResolveSheet(flow: flow), to: output, name: "4-resolve-chosen")
        await flow.saveChoices()
        await flow.complete()
        try render(MergeFlowView(flow: flow), to: output, name: "5-ready")
    }

    private func render(_ view: some View, to folder: String, name: String) throws {
        let host = NSHostingView(rootView: view.frame(width: Self.size.width, height: Self.size.height))
        host.frame = CGRect(origin: .zero, size: Self.size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
