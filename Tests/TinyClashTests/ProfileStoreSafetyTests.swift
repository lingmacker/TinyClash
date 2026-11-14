import Foundation
import XCTest
@testable import TinyClash

/// Subscription overwrite protection and edit-conflict detection in ProfileStore.
@MainActor
final class ProfileStoreSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TinyClash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ProfileStore {
        ProfileStore(profilesDirectory: directory, runtimeDirectory: directory.appendingPathComponent("runtime"),
                     indexURL: directory.appendingPathComponent("profiles.json"), validate: { _ in })
    }

    private func remoteProfile(_ name: String, content: String) throws -> Profile {
        var profile = Profile(name: name, kind: .remote, url: "https://example.test/\(name)",
                              fileName: "\(name).yaml", updatedAt: Date())
        let data = Data(content.utf8)
        try data.write(to: directory.appendingPathComponent(profile.fileName))
        profile.downloadedHash = ProfileStore.hash(data)
        return profile
    }

    func testLocalModificationIsDetectedAgainstDownloadedHash() throws {
        let store = makeStore()
        var profile = try remoteProfile("sub", content: "mixed-port: 7890\nrules: []\n")
        XCTAssertFalse(store.isLocallyModified(profile))

        try Data("mixed-port: 7890\nrules:\n  - MATCH,DIRECT\n".utf8).write(to: directory.appendingPathComponent(profile.fileName))
        XCTAssertTrue(store.isLocallyModified(profile))

        // Profiles downloaded before hashes existed are treated as unmodified rather than guessed.
        profile.downloadedHash = nil
        XCTAssertFalse(store.isLocallyModified(profile))
    }

    func testAppEditMarksSubscriptionAsModified() async throws {
        let store = makeStore()
        let profile = try remoteProfile("sub", content: "mixed-port: 7890\nrules: []\n")
        store.save([profile])
        let edit = try await store.prepareEdit(.addRule("DOMAIN,a.test,DIRECT"), to: profile)
        let profiles = try store.commit(edit, profiles: [profile])
        XCTAssertTrue(store.isLocallyModified(profiles[0]))
    }

    func testBackupKeepsLatestCopy() throws {
        let store = makeStore()
        let backups = directory.appendingPathComponent("backups")
        let profile = try remoteProfile("sub", content: "first\n")
        store.backup(profile, to: backups)
        try Data("second\n".utf8).write(to: directory.appendingPathComponent(profile.fileName))
        store.backup(profile, to: backups)
        let saved = try String(contentsOf: backups.appendingPathComponent("sub.yaml.bak"), encoding: .utf8)
        XCTAssertEqual(saved, "second\n")
    }

    func testOtherProfileIndexWriteDoesNotFailEdit() async throws {
        let store = makeStore()
        let a = try remoteProfile("a", content: "rules: []\n")
        var b = try remoteProfile("b", content: "rules: []\n")
        store.save([a, b])
        let edit = try await store.prepareEdit(.addRule("MATCH,DIRECT"), to: a)
        // A background update of another profile rewrites the index while A is validating.
        b.updatedAt = Date().addingTimeInterval(60)
        store.save([a, b])
        let profiles = try store.commit(edit, profiles: [a, b])
        XCTAssertEqual(profiles.count, 2)
        XCTAssertTrue(try String(contentsOf: a.fileURLIn(directory), encoding: .utf8).contains("MATCH,DIRECT"))
    }
}

private extension Profile {
    func fileURLIn(_ directory: URL) -> URL { directory.appendingPathComponent(fileName) }
}
