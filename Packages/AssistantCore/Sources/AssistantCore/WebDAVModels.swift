import Foundation

// MARK: - WebDAV 配置与文件模型

public struct WebDAVConfig: Codable, Sendable, Equatable {
    public var serverURL: String
    public var username: String
    public var remoteDirectory: String
    public var autoSyncEnabled: Bool
    public var lastSyncDate: Date?
    public var lastSyncStatus: String?

    public init(
        serverURL: String = "",
        username: String = "",
        remoteDirectory: String = "assistant-backup",
        autoSyncEnabled: Bool = false,
        lastSyncDate: Date? = nil,
        lastSyncStatus: String? = nil
    ) {
        self.serverURL = serverURL
        self.username = username
        self.remoteDirectory = remoteDirectory
        self.autoSyncEnabled = autoSyncEnabled
        self.lastSyncDate = lastSyncDate
        self.lastSyncStatus = lastSyncStatus
    }

    /// 是否已配置基础连接信息
    public var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct WebDAVFileItem: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let contentLength: Int64
    public let lastModified: Date?
    public let isCollection: Bool

    public init(
        name: String,
        path: String,
        contentLength: Int64 = 0,
        lastModified: Date? = nil,
        isCollection: Bool = false
    ) {
        self.name = name
        self.path = path
        self.contentLength = contentLength
        self.lastModified = lastModified
        self.isCollection = isCollection
    }

    /// 格式化文件大小
    public var formattedSize: String {
        if isCollection { return "文件夹" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: contentLength)
    }
}

// MARK: - 请求构建工厂

public enum WebDAVRequestFactory: Sendable {
    /// 生成 HTTP Basic Authorization 头
    public static func makeAuthHeader(username: String, password: String) -> String {
        let credential = "\(username):\(password)"
        let data = Data(credential.utf8)
        return "Basic \(data.base64EncodedString())"
    }

    /// 规范化服务器地址与远端目录拼接
    public static func makeDirectoryURL(serverURL: String, remoteDirectory: String) -> URL? {
        guard var trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard var base = URL(string: trimmed) else { return nil }
        let cleanDir = remoteDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !cleanDir.isEmpty {
            base.appendPathComponent(cleanDir)
        }
        return base
    }

    /// 构建具体文件的完整 URL
    public static func makeFileURL(serverURL: String, remoteDirectory: String, filename: String) -> URL? {
        guard let dirURL = makeDirectoryURL(serverURL: serverURL, remoteDirectory: remoteDirectory) else {
            return nil
        }
        return dirURL.appendingPathComponent(filename)
    }

    /// 把服务器在 PROPFIND 里给出的 `<d:href>` 解析成本机配置目录下的文件 URL。
    ///
    /// href 是外部输入：跨源的绝对地址会让 `Authorization: Basic` 跟着请求离开用户自己的
    /// NAS，因此这里只承认三种情况——相对路径、与配置同源同 scheme 且默认端口等价的绝对
    /// 地址，且路径必须落在备份目录内；其余一律返回 nil，由调用方拒发请求。
    public static func makeFileURL(
        fromHref href: String,
        serverURL: String,
        remoteDirectory: String
    ) -> URL? {
        guard let dirURL = makeDirectoryURL(serverURL: serverURL, remoteDirectory: remoteDirectory) else {
            return nil
        }
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var path = trimmed
        if hasAbsoluteScheme(trimmed) {
            // 先按原样解析（已编码的 href 保持 %E5… 不被二次转义），失败再补编码
            let absolute = URL(string: trimmed)
                ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
            guard let absolute,
                  let configuredOrigin = origin(of: dirURL),
                  let hrefOrigin = origin(of: absolute),
                  configuredOrigin == hrefOrigin else {
                return nil
            }
            path = absolute.path
        }
        // 解析器给出的是已解码文本，但直接调用方可能传原始 href，两种都吃
        path = path.removingPercentEncoding ?? path

        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanDirectory = dirURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPath.isEmpty else { return nil }
        guard cleanDirectory.isEmpty
            || cleanPath == cleanDirectory
            || cleanPath.hasPrefix(cleanDirectory + "/") else {
            return nil
        }
        guard let lastSegment = cleanPath.split(separator: "/").last, lastSegment != ".." else {
            return nil
        }
        return dirURL.appendingPathComponent(String(lastSegment))
    }

    /// 配置是否以明文 http 传输——此时 Basic 凭据与备份文件都会明文过网。
    /// 未写 scheme 时按 `makeDirectoryURL` 的默认升级规则视为 https，不算明文。
    public static func usesInsecureTransport(serverURL: String) -> Bool {
        serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("http://")
    }

    private static func hasAbsoluteScheme(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
    }

    /// scheme + 主机 + 端口（补默认端口，避免 `https://host` 与 `https://host:443` 被判成两地）
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        let port = url.port ?? defaultPort(for: scheme)
        if let port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// 构建 PROPFIND 请求（Depth: 1 列举目录）
    public static func makePROPFINDRequest(url: URL, authHeader: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "PROPFIND"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("1", forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:getcontentlength/>
            <d:getlastmodified/>
            <d:resourcetype/>
          </d:prop>
        </d:propfind>
        """
        req.httpBody = propfindBody.data(using: .utf8)
        req.timeoutInterval = 20
        return req
    }

    /// 构建 MKCOL 请求（创建远端目录）
    public static func makeMKCOLRequest(url: URL, authHeader: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "MKCOL"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return req
    }

    /// 构建 PUT 请求（上传备份文件）
    public static func makePUTRequest(url: URL, data: Data, authHeader: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 60
        return req
    }

    /// 构建 GET 请求（下载备份文件）
    public static func makeGETRequest(url: URL, authHeader: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60
        return req
    }

    /// 构建 DELETE 请求
    public static func makeDELETERequest(url: URL, authHeader: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        return req
    }
}

// MARK: - WebDAV XML 响应解析器 (RFC 4918 multistatus)

public final class WebDAVXMLParser: NSObject, XMLParserDelegate {
    private var items: [WebDAVFileItem] = []
    private var currentPath: String = ""
    private var currentName: String = ""
    private var currentSize: Int64 = 0
    private var currentModifiedString: String = ""
    private var currentIsCollection: Bool = false
    private var currentElementText: String = ""

    private static let rfc1123DateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func parseMultistatus(xmlData: Data, baseURL: URL) -> [WebDAVFileItem] {
        let parserInstance = WebDAVXMLParser()
        let xmlParser = XMLParser(data: xmlData)
        xmlParser.delegate = parserInstance
        guard xmlParser.parse() else { return [] }

        let baseCleanPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // 过滤掉目录自身，保留子文件或子目录
        return parserInstance.items.filter { item in
            let itemCleanPath = item.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return !itemCleanPath.isEmpty && itemCleanPath != baseCleanPath
        }
    }

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String : String] = [:]
    ) {
        currentElementText = ""
        let tag = elementName.lowercased()
        if tag.hasSuffix("response") {
            currentPath = ""
            currentName = ""
            currentSize = 0
            currentModifiedString = ""
            currentIsCollection = false
        } else if tag.hasSuffix("collection") {
            currentIsCollection = true
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentElementText += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let tag = elementName.lowercased()
        let trimmed = currentElementText.trimmingCharacters(in: .whitespacesAndNewlines)

        if tag.hasSuffix("href") {
            currentPath = trimmed.removingPercentEncoding ?? trimmed
        } else if tag.hasSuffix("displayname") {
            currentName = trimmed
        } else if tag.hasSuffix("getcontentlength") {
            currentSize = Int64(trimmed) ?? 0
        } else if tag.hasSuffix("getlastmodified") {
            currentModifiedString = trimmed
        } else if tag.hasSuffix("response") {
            var fileName = currentName
            if fileName.isEmpty {
                let segments = currentPath.split(separator: "/")
                fileName = segments.last.map(String.init) ?? currentPath
            }

            let date = Self.rfc1123DateFormatter.date(from: currentModifiedString)
                ?? Self.iso8601Formatter.date(from: currentModifiedString)

            let item = WebDAVFileItem(
                name: fileName,
                path: currentPath,
                contentLength: currentSize,
                lastModified: date,
                isCollection: currentIsCollection
            )
            items.append(item)
        }
    }
}
