import XCTest
@testable import AssistantCore

final class WebDAVTests: XCTestCase {
    func testAuthHeaderGeneration() {
        let auth = WebDAVRequestFactory.makeAuthHeader(username: "admin", password: "password123")
        XCTAssertTrue(auth.hasPrefix("Basic "))
        let base64Part = String(auth.dropFirst("Basic ".count))
        let decoded = Data(base64Encoded: base64Part).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(decoded, "admin:password123")
    }

    func testDirectoryAndFileURLConcatenation() {
        let dirURL = WebDAVRequestFactory.makeDirectoryURL(
            serverURL: "https://nas.lan:5006/dav/",
            remoteDirectory: "/assistant-backup/"
        )
        XCTAssertEqual(dirURL?.absoluteString, "https://nas.lan:5006/dav/assistant-backup")

        let fileURL = WebDAVRequestFactory.makeFileURL(
            serverURL: "http://192.168.1.100:8080",
            remoteDirectory: "backups",
            filename: "assistant_20261027.assistantbackup"
        )
        XCTAssertEqual(fileURL?.absoluteString, "http://192.168.1.100:8080/backups/assistant_20261027.assistantbackup")
    }

    func testWebDAVRequestsFactory() {
        guard let url = URL(string: "https://nas.lan:5006/dav/backup/file.bin") else {
            XCTFail("Invalid URL")
            return
        }
        let auth = "Basic dGVzdDp0ZXN0"

        let propfind = WebDAVRequestFactory.makePROPFINDRequest(url: url, authHeader: auth)
        XCTAssertEqual(propfind.httpMethod, "PROPFIND")
        XCTAssertEqual(propfind.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(propfind.value(forHTTPHeaderField: "Authorization"), auth)

        let mkcol = WebDAVRequestFactory.makeMKCOLRequest(url: url, authHeader: auth)
        XCTAssertEqual(mkcol.httpMethod, "MKCOL")

        let testData = Data("encrypted_backup_payload".utf8)
        let put = WebDAVRequestFactory.makePUTRequest(url: url, data: testData, authHeader: auth)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.httpBody, testData)

        let get = WebDAVRequestFactory.makeGETRequest(url: url, authHeader: auth)
        XCTAssertEqual(get.httpMethod, "GET")

        let del = WebDAVRequestFactory.makeDELETERequest(url: url, authHeader: auth)
        XCTAssertEqual(del.httpMethod, "DELETE")
    }

    func testMultistatusXMLParsing() {
        let sampleXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <!-- 根目录自身（解析时应自动滤除） -->
          <d:response>
            <d:href>/dav/assistant-backup/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <!-- 历史备份 1 -->
          <d:response>
            <d:href>/dav/assistant-backup/assistant_backup_20261027_120000.assistantbackup</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>assistant_backup_20261027_120000.assistantbackup</d:displayname>
                <d:getcontentlength>1048576</d:getcontentlength>
                <d:getlastmodified>Tue, 27 Oct 2026 12:00:00 GMT</d:getlastmodified>
                <d:resourcetype/>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
          <!-- 历史备份 2 -->
          <d:response>
            <d:href>/dav/assistant-backup/assistant_backup_20261026_093000.assistantbackup</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>assistant_backup_20261026_093000.assistantbackup</d:displayname>
                <d:getcontentlength>524288</d:getcontentlength>
                <d:getlastmodified>Mon, 26 Oct 2026 09:30:00 GMT</d:getlastmodified>
                <d:resourcetype/>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        guard let baseURL = URL(string: "https://nas.lan:5006/dav/assistant-backup/") else {
            XCTFail("Invalid Base URL")
            return
        }

        let items = WebDAVXMLParser.parseMultistatus(xmlData: Data(sampleXML.utf8), baseURL: baseURL)
        XCTAssertEqual(items.count, 2)

        let item1 = items[0]
        XCTAssertEqual(item1.name, "assistant_backup_20261027_120000.assistantbackup")
        XCTAssertEqual(item1.contentLength, 1048576)
        XCTAssertTrue(item1.formattedSize.contains("MB"))
        XCTAssertFalse(item1.isCollection)
        XCTAssertNotNil(item1.lastModified)

        let item2 = items[1]
        XCTAssertEqual(item2.name, "assistant_backup_20261026_093000.assistantbackup")
        XCTAssertEqual(item2.contentLength, 524288)
        XCTAssertTrue(item2.formattedSize.contains("KB"))
    }

    func testConfigIsConfiguredProperty() {
        var config = WebDAVConfig()
        XCTAssertFalse(config.isConfigured)

        config.serverURL = "https://nas.lan:5006"
        XCTAssertFalse(config.isConfigured)

        config.username = "admin"
        XCTAssertTrue(config.isConfigured)
    }
}
