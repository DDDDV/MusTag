import Foundation
import MusicKit
import XCTest
@testable import MusTag

final class AppleMusicMetadataTests: XCTestCase {
    func testInvalidCatalogIDsFailBeforePermissionOrNetworking() async {
        for id in ["", " ", "0", "-1", "123/456", "١٢٣", "18446744073709551616", "library-id"] {
            do {
                _ = try await AppleMusicMetadataService.song(id: id,
                    authorizationStatus: { XCTFail("Invalid IDs must not check authorization"); return .authorized },
                    requestAuthorization: { XCTFail("Invalid IDs must not request authorization"); return .denied },
                    loadSong: { _ in XCTFail("Invalid IDs must not reach the catalog"); return nil },
                    loadAlbums: { _ in XCTFail("Invalid IDs must not load albums"); return nil })
                XCTFail("Expected invalid ID: \(id)")
            } catch { XCTAssertTrue(error is MusTagError) }
        }
    }

    func testDeniedOrRestrictedAccessNeverQueriesCatalogOrRequestsAgain() async {
        for status in [MusicAuthorization.Status.denied, .restricted] {
            do {
                _ = try await lookup(status: status,
                    loadSong: { _ in XCTFail("Denied access must not query the catalog"); return nil })
                XCTFail("Expected permission error")
            } catch {
                XCTAssertTrue(error is MusTagError)
                XCTAssertTrue(error.localizedDescription.contains("Shazam"))
            }
        }
    }

    func testFirstPermissionRequestCanAuthorizeExactCatalogLookup() async throws {
        let song = try fixtureSong()
        let authorization = expectation(description: "Music permission requested")
        let result = try await lookup(id: " 123 ", status: .notDetermined,
            requestAuthorization: { authorization.fulfill(); return .authorized },
            loadSong: { id in XCTAssertEqual(id, "123"); return song })
        await fulfillment(of: [authorization], timeout: 1)
        XCTAssertEqual(result?.id, "123")
        XCTAssertEqual(result?.title, "Song")
    }

    func testDecliningFirstPermissionRequestKeepsCatalogUnused() async {
        do {
            _ = try await lookup(status: .notDetermined, requestAuthorization: { .denied },
                loadSong: { _ in XCTFail("Declined access must not query the catalog"); return nil })
            XCTFail("Expected permission error")
        } catch { XCTAssertTrue(error is MusTagError) }
    }

    func testExactCatalogSongSuppliesReleaseFieldsAndPersists() async throws {
        let song = try fixtureSong()
        let album = try fixtureAlbum(id: "456", artist: "Various Artists")
        let optional = try await lookup(loadSong: { _ in song }, loadAlbums: { item in
            XCTAssertEqual(item.id.rawValue, "123")
            return [album]
        })
        let result = try XCTUnwrap(optional)
        XCTAssertEqual(result.artist, "Artist")
        XCTAssertEqual(result.albumTitle, "Album")
        XCTAssertEqual(result.albumArtist, "Various Artists")
        XCTAssertEqual(result.trackNumber, 7)
        XCTAssertEqual(result.discNumber, 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let release = try XCTUnwrap(result.releaseDate)
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: release),
                       DateComponents(year: 2001, month: 12, day: 31))
        XCTAssertEqual(result.isrc, "USAAA0000001")
        XCTAssertEqual(result.duration, 210)
        XCTAssertEqual(result.genres, ["Pop"])
        XCTAssertEqual(result.url?.absoluteString, "https://music.apple.com/us/song/123")
        XCTAssertEqual(result.artworkURL?.absoluteString, "https://is1-ssl.mzstatic.com/artwork/1200x1200.jpg")
        XCTAssertEqual(try JSONDecoder().decode(AppleMusicSongMetadata.self,
                                                from: JSONEncoder().encode(result)), result)
    }

    func testUnavailableOrDifferentCatalogIDNeverLoadsRelationships() async throws {
        let unrelated = try fixtureSong(id: "999")
        for song in [nil, unrelated] {
            let result = try await lookup(loadSong: { _ in song }, loadAlbums: { _ in
                XCTFail("Missing or unrelated songs must not load albums")
                return nil
            })
            XCTAssertNil(result)
        }
    }

    func testOptionalAlbumFailurePreservesKnownSongFields() async throws {
        let song = try fixtureSong()
        let result = try await lookup(loadSong: { _ in song }, loadAlbums: { _ in throw URLError(.timedOut) })
        XCTAssertEqual(result?.albumTitle, "Album")
        XCTAssertEqual(result?.trackNumber, 7)
        XCTAssertEqual(result?.discNumber, 2)
        XCTAssertNotNil(result?.releaseDate)
        XCTAssertNil(result?.albumArtist, "Song artist must not be guessed as album artist")
    }

    func testAmbiguousAlbumsDoNotChooseAnAlbumArtist() async throws {
        let song = try fixtureSong()
        let first = try fixtureAlbum(id: "456", artist: "Artist")
        let second = try fixtureAlbum(id: "789", artist: "Various Artists")
        let result = try await lookup(loadSong: { _ in song }, loadAlbums: { _ in [first, second] })
        XCTAssertNil(result?.albumArtist)
        XCTAssertEqual(result?.trackNumber, 7)
    }

    func testMissingReleaseFieldsRemainUnknown() throws {
        let song = try fixtureSong(attributes: ["name": "Song", "artistName": "Artist", "genreNames": []])
        let result = AppleMusicMetadataService.metadata(from: song)
        XCTAssertNil(result.albumTitle)
        XCTAssertNil(result.albumArtist)
        XCTAssertNil(result.releaseDate)
        XCTAssertNil(result.trackNumber)
        XCTAssertNil(result.discNumber)
        XCTAssertNil(result.duration)
        XCTAssertNil(result.artworkURL)
        XCTAssertNil(result.url)
    }

    func testInvalidPositionsAndUnsafeLinksAreNotExposed() throws {
        let song = try fixtureSong(attributes: [
            "name": " Song ", "artistName": " Artist ", "genreNames": ["Pop", " "],
            "trackNumber": 0, "discNumber": -1, "durationInMillis": -1000,
            "url": "https://user:secret@music.apple.com/song/123",
            "artwork": ["width": 10, "height": 10, "url": "http://is1-ssl.mzstatic.com/{w}x{h}.jpg"]
        ])
        let result = AppleMusicMetadataService.metadata(from: song)
        XCTAssertEqual(result.title, "Song")
        XCTAssertEqual(result.artist, "Artist")
        XCTAssertEqual(result.genres, ["Pop"])
        XCTAssertNil(result.trackNumber)
        XCTAssertNil(result.discNumber)
        XCTAssertNil(result.duration)
        XCTAssertNil(result.url)
        XCTAssertNil(result.artworkURL)
    }

    func testCatalogAndRelationshipCancellationAlwaysPropagate() async throws {
        let song = try fixtureSong()
        for error in [CancellationError() as Error, URLError(.cancelled) as Error] {
            do {
                _ = try await lookup(loadSong: { _ in throw error })
                XCTFail("Catalog cancellation must propagate")
            } catch { XCTAssertTrue(error is CancellationError) }
            do {
                _ = try await lookup(loadSong: { _ in song }, loadAlbums: { _ in throw error })
                XCTFail("Optional album cancellation must propagate")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    func testCancellingInFlightCatalogLookupStopsSupplementation() async {
        let started = expectation(description: "Catalog lookup started")
        let task = Task {
            try await lookup(loadSong: { _ in
                started.fulfill()
                try await Task.sleep(nanoseconds: 30_000_000_000)
                return nil
            }, loadAlbums: { _ in XCTFail("Cancelled lookups must not load albums"); return nil })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled supplementation must not return metadata")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTokenFailuresIdentifyConfigurationPermissionAndAccountActions() {
        let developer = AppleMusicMetadataService.diagnosticMessage(for: MusicTokenRequestError.developerTokenRequestFailed)
        XCTAssertTrue(developer.contains("MusicKit developerTokenRequestFailed"))
        XCTAssertTrue(developer.contains("App ID"))
        XCTAssertTrue(developer.contains("Apple Developer"))
        XCTAssertTrue(developer.contains(L10n.text("connection", "网络")),
                      "Token failure must not assert that App Service configuration is its only possible cause")

        let cases: [(MusicTokenRequestError, String)] = [
            (.permissionDenied, L10n.text("Settings", "系统设置")),
            (.userTokenRevoked, L10n.text("Settings", "系统设置")),
            (.userNotSignedIn, L10n.text("Sign in", "登录")),
            (.privacyAcknowledgementRequired, L10n.text("privacy", "隐私")),
            (.userTokenRequestFailed, "MusicKit userTokenRequestFailed"),
            (.unknown, "MusicKit unknown")
        ]
        for (error, expected) in cases {
            XCTAssertTrue(AppleMusicMetadataService.diagnosticMessage(for: error).contains(expected))
        }
    }

    func testHTTPDiagnosticsSeparateAuthenticationCatalogAvailabilityAndServiceFailures() {
        let cases: [(Int, String)] = [
            (401, "App ID"),
            (403, L10n.text("authorization", "认证")),
            (404, L10n.text("current Apple Music catalog", "当前 Apple Music 曲库")),
            (429, L10n.text("too many requests", "过于频繁")),
            (503, L10n.text("temporarily unavailable", "暂不可用")),
            (400, L10n.text("could not complete", "无法完成"))
        ]
        for (status, expected) in cases {
            let message = AppleMusicMetadataService.diagnosticMessage(httpStatus: status, code: 12345)
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertTrue(message.contains("HTTP \(status)"), message)
            XCTAssertTrue(message.contains("Apple Music 12345"), message)
        }
    }

    func testNetworkAndUnknownDiagnosticsNeverExposePrivateErrorDetails() {
        let secretURL = URL(string: "https://private-token.example/path?token=secret-token")!
        let info: [String: Any] = [NSLocalizedDescriptionKey: "private-description secret-token",
                                   NSURLErrorFailingURLErrorKey: secretURL,
                                   NSLocalizedFailureReasonErrorKey: "private-reason"]
        let networkCases: [(URLError.Code, String)] = [
            (.timedOut, L10n.text("timed out", "超时")),
            (.notConnectedToInternet, L10n.text("cannot access the network", "无法使用网络")),
            (.dnsLookupFailed, L10n.text("resolved", "解析")),
            (.networkConnectionLost, L10n.text("interrupted", "中断")),
            (.serverCertificateUntrusted, L10n.text("secure connection", "安全连接"))
        ]
        for (code, expected) in networkCases {
            let message = AppleMusicMetadataService.diagnosticMessage(for: URLError(code, userInfo: info))
            XCTAssertTrue(message.contains(expected), message)
            XCTAssertTrue(message.contains("NSURLErrorDomain \(code.rawValue)"), message)
            XCTAssertFalse(message.contains("secret"), message)
            XCTAssertFalse(message.contains("private"), message)
            XCTAssertFalse(message.contains("https://"), message)
        }
        let unknown = NSError(domain: "private-domain-secret-token", code: 81234, userInfo: info)
        let message = AppleMusicMetadataService.diagnosticMessage(for: unknown)
        XCTAssertTrue(message.contains("81234"))
        XCTAssertFalse(message.contains("secret"))
        XCTAssertFalse(message.contains("private"))
        XCTAssertFalse(message.contains("https://"))
    }

    private func lookup(
        id: String = "123", status: MusicAuthorization.Status = .authorized,
        requestAuthorization: AppleMusicMetadataService.AuthorizationRequest = {
            XCTFail("Determined authorization must not prompt again"); return .denied
        },
        loadSong: AppleMusicMetadataService.SongLoader = { _ in nil },
        loadAlbums: AppleMusicMetadataService.AlbumLoader = { _ in nil }
    ) async throws -> AppleMusicSongMetadata? {
        try await AppleMusicMetadataService.song(id: id, authorizationStatus: { status },
            requestAuthorization: requestAuthorization, loadSong: loadSong, loadAlbums: loadAlbums)
    }

    private func fixtureSong(id: String = "123", attributes: [String: Any]? = nil) throws -> Song {
        let attributes = attributes ?? [
            "name": "Song", "artistName": "Artist", "albumName": "Album", "genreNames": ["Pop"],
            "releaseDate": "2001-12-31", "trackNumber": 7, "discNumber": 2,
            "isrc": "USAAA0000001", "durationInMillis": 210000,
            "url": "https://music.apple.com/us/song/123",
            "artwork": ["width": 1200, "height": 1200,
                        "url": "https://is1-ssl.mzstatic.com/artwork/{w}x{h}.jpg"]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "type": "songs", "attributes": attributes])
        return try JSONDecoder().decode(Song.self, from: data)
    }

    private func fixtureAlbum(id: String, artist: String) throws -> Album {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "type": "albums",
            "attributes": ["name": "Album", "artistName": artist, "genreNames": ["Pop"], "trackCount": 10]
        ])
        return try JSONDecoder().decode(Album.self, from: data)
    }
}
