import Foundation
import Testing

@testable import BanditoKit

@Suite struct ReleaseAssetTests {
    @Test func unameOutputMapsToTheReleaseAsset() {
        #expect(ReleaseAsset.name(unameSM: "Linux x86_64") == "bandito-x86_64-unknown-linux-gnu.tar.gz")
        #expect(ReleaseAsset.name(unameSM: "Linux aarch64") == "bandito-aarch64-unknown-linux-gnu.tar.gz")
        #expect(ReleaseAsset.name(unameSM: "Darwin arm64") == "bandito-aarch64-apple-darwin.tar.gz")
        #expect(ReleaseAsset.name(unameSM: "Darwin x86_64") == "bandito-x86_64-apple-darwin.tar.gz")
        #expect(ReleaseAsset.name(unameSM: "Linux amd64") == "bandito-x86_64-unknown-linux-gnu.tar.gz")
    }

    @Test func unsupportedKernelsAndMachinesHaveNoAsset() {
        #expect(ReleaseAsset.name(unameSM: "FreeBSD amd64") == nil)
        #expect(ReleaseAsset.name(unameSM: "Linux riscv64") == nil)
        #expect(ReleaseAsset.name(unameSM: "Linux") == nil)
        #expect(ReleaseAsset.name(unameSM: "") == nil)
    }

    @Test func theTagOfAnAppVersionIsVXYZ() {
        #expect(GitHubReleaseSource.tag(forAppVersion: "0.1.0") == "v0.1.0")
        #expect(GitHubReleaseSource.tag(forAppVersion: "v0.2.0") == "v0.2.0")
        #expect(GitHubReleaseSource.tag(forAppVersion: "—") == nil)
        #expect(GitHubReleaseSource.tag(forAppVersion: "dev") == nil)
    }

    @Test func releaseUrlsPointAtGitHubReleases() {
        #expect(
            GitHubReleaseSource.url(version: "v0.1.0", file: "SHA256SUMS")
                == URL(string: "https://github.com/banditohq/bandito/releases/download/v0.1.0/SHA256SUMS"))
        #expect(
            GitHubReleaseSource.url(version: nil, file: "SHA256SUMS.sig")
                == URL(string: "https://github.com/banditohq/bandito/releases/latest/download/SHA256SUMS.sig"))
    }
}

@Suite struct RedirectPolicyTests {
    /// Stores what the redirect callback was given, for a `@Sendable` closure.
    final class Captured: @unchecked Sendable {
        // @unchecked: `value` is written once, from the callback, before the test reads it.
        var called = false
        var request: URLRequest?
    }

    private let github = URL(string: "https://github.com/banditohq/bandito/releases/download/v0.1.0/SHA256SUMS")!

    @Test func gitHubAndItsAssetHostsOverHttpsAreAllowed() {
        #expect(GitHubReleaseSource.allowsRedirect(to: github))
        #expect(
            GitHubReleaseSource.allowsRedirect(
                to: URL(string: "https://objects.githubusercontent.com/github-production/x")!))
        #expect(
            GitHubReleaseSource.allowsRedirect(
                to: URL(string: "https://release-assets.githubusercontent.com/github-production/x")!))
    }

    @Test func otherHostsPlainHttpAndOddPortsAreRefused() {
        for text in [
            "http://github.com/banditohq/bandito/releases/x",
            "https://evil.example/bandito",
            "https://github.com.evil.example/bandito",
            "https://objects.githubusercontent.com.evil.example/x",
            "https://github.com:8443/x",
            "https://user@github.com/x",
            "ftp://github.com/x",
        ] {
            #expect(GitHubReleaseSource.allowsRedirect(to: URL(string: text)!) == false, "\(text)")
        }
    }

    @Test func aRedirectToAForeignHostIsRefusedAndCancelled() throws {
        let guardDelegate = RedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: github)
        let response = try #require(
            HTTPURLResponse(url: github, statusCode: 302, httpVersion: nil, headerFields: nil))
        let captured = Captured()

        guardDelegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://evil.example/bandito")!),
            completionHandler: { request in
                captured.called = true
                captured.request = request
            })

        #expect(captured.called)
        #expect(captured.request == nil)
        #expect(guardDelegate.refused)
    }

    @Test func aRedirectToGitHubsAssetHostIsFollowed() throws {
        let guardDelegate = RedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: github)
        let response = try #require(
            HTTPURLResponse(url: github, statusCode: 302, httpVersion: nil, headerFields: nil))
        let target = URL(string: "https://objects.githubusercontent.com/github-production/SHA256SUMS")!
        let captured = Captured()

        guardDelegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: target),
            completionHandler: { request in
                captured.called = true
                captured.request = request
            })

        #expect(captured.called)
        #expect(captured.request?.url == target)
        #expect(guardDelegate.refused == false)
    }
}

@Suite struct ReleaseTagTests {
    @Test func aRedirectToAReleaseDownloadNamesTheTag() throws {
        let guardDelegate = RedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        let start = URL(string: "https://github.com/banditohq/bandito/releases/latest/download/x")!
        let task = session.dataTask(with: start)
        let response = try #require(HTTPURLResponse(url: start, statusCode: 302, httpVersion: nil, headerFields: nil))

        guardDelegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://github.com/banditohq/bandito/releases/download/v0.3.0/x")!),
            completionHandler: { _ in })

        #expect(guardDelegate.followedTag == "v0.3.0")
        #expect(guardDelegate.refused == false)
    }

    @Test func aCdnRedirectKeepsTheTagOfTheReleaseItCameFrom() throws {
        let guardDelegate = RedirectGuard()
        let session = URLSession(configuration: .ephemeral)
        let start = URL(string: "https://github.com/banditohq/bandito/releases/download/v0.3.0/x")!
        let task = session.dataTask(with: start)
        let response = try #require(HTTPURLResponse(url: start, statusCode: 302, httpVersion: nil, headerFields: nil))

        guardDelegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://objects.githubusercontent.com/github-production/x")!),
            completionHandler: { _ in })

        #expect(guardDelegate.followedTag == nil)
        #expect(guardDelegate.refused == false)
    }

    @Test func onlyVersionsAreTakenAsTags() throws {
        let url = { (text: String) in URL(string: "https://github.com/banditohq/bandito/releases/download/\(text)/x")! }
        #expect(GitHubReleaseSource.tag(inDownload: url("v0.3.0")) == "v0.3.0")
        #expect(GitHubReleaseSource.tag(inDownload: url("latest")) == nil)
        #expect(GitHubReleaseSource.tag(inDownload: url("..")) == nil)
    }
}
