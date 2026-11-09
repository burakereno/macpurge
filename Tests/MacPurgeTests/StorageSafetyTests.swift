import Foundation
import Testing
@testable import MacPurge
@testable import MacPurgeCore

struct StorageSafetyTests {
    @Test func onlyKnownRegenerableRootsQualifyAsSafe() throws {
        let home = URL(fileURLWithPath: "/fixture")
        let project = home.appending(path: "Projects/go-build")
        let roots = ScanRoot.catalog(home: home, projects: [project])
        let safePaths = roots.filter { $0.profile.assessment(for: .complete)?.level == .safe }.map(\.url.path)
        #expect(Set(safePaths) == [
            "/fixture/.npm/_cacache", "/fixture/Library/Caches/go-build",
            "/fixture/Library/Caches/pip/http", "/fixture/Library/Caches/pip/http-v2",
            "/fixture/Library/Caches/Homebrew/downloads", "/fixture/.gradle/caches",
            "/fixture/.expo/android-apk-cache", "/fixture/.expo/ios-simulator-app-cache",
            "/fixture/.expo/native-modules-cache", "/fixture/.expo/schema-cache",
            "/fixture/.expo/versions-cache", "/fixture/.expo/expo-go",
        ])
        let projectRoot = try #require(roots.first { $0.group == .projects })
        #expect(projectRoot.profile.assessment(for: .complete)?.level == .review)
        #expect(StorageProfile.unknown.assessment(for: .complete)?.level == .review)
    }

    @Test func incompleteOrMissingDataNeverReceivesASafeBadge() {
        let partial = StorageProfile.npmCache.assessment(for: .partial)
        #expect(partial?.level == .review)
        #expect(partial?.reason.isEmpty == false)
        for state: ReadState? in [nil, .absent, .unavailable("Erişim izni yok")] {
            #expect(StorageProfile.npmCache.assessment(for: state) == nil)
        }
    }
}
