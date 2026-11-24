import Foundation
import ImageIO
import AppKit

/// Web search (DuckDuckGo's HTML page, only the search words sent) and page
/// text, fetched in the background.
enum WebAccess {

    struct Result {
        let title: String
        let url: String
        let snippet: String
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral   // no cookies kept between searches
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    // MARK: - Search

    /// The top results as text for the model: numbered titles, addresses and snippets.
    static func search(_ query: String) async -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "What should I search for?" }
        guard let results = try? await results(for: trimmed) else {
            return "I couldn't reach the internet just now."
        }
        guard !results.isEmpty else { return "No results for \"\(trimmed)\"." }
        // Four, snippets cut short: the model reads every word before it
        // answers (six full results took it ~5 s to read).
        return results.prefix(4).enumerated().map { index, result in
            "\(index + 1). \(result.title)\n   \(result.url)\n   \(String(result.snippet.prefix(220)))"
        }.joined(separator: "\n")
    }

    /// DuckDuckGo first; if it returns nothing (it sometimes asks automated
    /// visitors to prove they're human), Wikipedia's open search API, which
    /// always answers but only covers Wikipedia.
    static func results(for query: String) async throws -> [Result] {
        if let found = try? await duckDuckGo(query), !found.isEmpty { return found }
        ActivityLog.write(.system, "web search: DuckDuckGo gave nothing, trying Wikipedia")
        return try await wikipedia(query)
    }

    private static func wikipedia(_ query: String) async throws -> [Result] {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query), URLQueryItem(name: "srlimit", value: "6"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return [] }
        let text = try await fetch(url)
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let search = (json["query"] as? [String: Any])?["search"] as? [[String: Any]] else { return [] }
        return search.compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            let page = title.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
            return Result(title: title, url: "https://en.wikipedia.org/wiki/\(page)",
                          snippet: plainText(item["snippet"] as? String ?? ""))
        }
    }

    private static func duckDuckGo(_ query: String) async throws -> [Result] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }
        let html = try await fetch(url)

        // Each result: <a class="result__a" href="…">title</a> … <a class="result__snippet" …>snippet</a>
        let linkPattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"class="result__snippet"[^>]*>(.*?)</a>"#
        let links = matches(linkPattern, in: html)
        let snippets = matches(snippetPattern, in: html).map { $0[0] }

        return links.enumerated().compactMap { index, groups in
            guard groups.count == 2 else { return nil }
            let address = realAddress(decodeEntities(groups[0]))
            // Ads point back at DuckDuckGo itself; skip them.
            guard !address.contains("duckduckgo.com/y.js") else { return nil }
            return Result(title: plainText(groups[1]),
                          url: address,
                          snippet: index < snippets.count ? plainText(snippets[index]) : "")
        }
    }

    /// DuckDuckGo wraps result links in a redirect (`//duckduckgo.com/l/?uddg=<real address>`).
    private static func realAddress(_ href: String) -> String {
        let full = href.hasPrefix("//") ? "https:" + href : href
        if let components = URLComponents(string: full),
           let real = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return real
        }
        return full
    }

    // MARK: - Reading

    /// A page's title and readable text, trimmed for the model.
    static func read(_ address: String) async -> String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), let host = url.host,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return "That isn't a web address." }
        // The internet only: never the router page, a dev server or
        // anything else on this Mac or its network.
        guard await !isLocal(host) else {
            ActivityLog.write(.blocked, "read_webpage: \(host) is on this Mac or the local network")
            return "Not done: \(host) is on this Mac or the local network — I only read the internet."
        }
        guard let html = try? await fetch(url, publicOnly: true) else { return "I couldn't load \(host)." }

        let title = matches(#"<title[^>]*>(.*?)</title>"#, in: html).first.map { plainText($0[0]) } ?? ""
        var body = html
        // Scripts, styles and page furniture aren't the content.
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form", "iframe"] {
            body = body.replacingOccurrences(of: "(?is)<\(tag)\\b.*?</\(tag)>", with: " ",
                                             options: .regularExpression)
        }
        // Paragraph-ish tags become line breaks, so the text keeps its shape.
        body = body.replacingOccurrences(of: "(?i)<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n",
                                         options: .regularExpression)
        var content = plainText(body, keepLines: true)
        if content.count > 4000 { content = String(content.prefix(4000)) + "…" }
        guard !content.isEmpty else {
            return "\(title)\n(The page has no readable text without a browser — open_website can show it to the user.)"
        }
        return "\(title)\n\(url.absoluteString)\n\n\(content)"
    }

    // MARK: - Pictures

    /// A picture found on the web, for Pip's window: a small JPEG and the
    /// page it came from.
    struct Picture: Sendable {
        let title: String
        let page: URL
        let thumbnail: Data
        /// The full-size picture, for saving (the thumbnail is 360 px).
        var full: URL? = nil
    }

    /// Pictures for the notch: DuckDuckGo's image tab (unofficial), else each
    /// top result's `og:image`.
    static func pictures(for query: String, limit: Int = 10) async -> [Picture] {
        if let images = try? await duckDuckGoImages(query, limit: limit), !images.isEmpty {
            ActivityLog.write(.system, "pictures: \(images.count) from DuckDuckGo images")
            return images
        }
        ActivityLog.write(.system, "pictures: DuckDuckGo images gave nothing — reading the result pages instead")
        return await pagePictures(for: query, limit: limit)
    }

    /// DuckDuckGo's image tab: its page token (`vqd`), then `i.js`.
    private static func duckDuckGoImages(_ query: String, limit: Int) async throws -> [Picture] {
        var start = URLComponents(string: "https://duckduckgo.com/")!
        start.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "iax", value: "images"),
                            URLQueryItem(name: "ia", value: "images")]
        let page = try await fetch(start.url!)
        guard let token = matches(#"vqd\s*=\s*["']?([0-9-]+)"#, in: page).first?.first else { return [] }
        var list = URLComponents(string: "https://duckduckgo.com/i.js")!
        list.queryItems = [URLQueryItem(name: "l", value: "us-en"), URLQueryItem(name: "o", value: "json"),
                           URLQueryItem(name: "q", value: query), URLQueryItem(name: "vqd", value: token),
                           URLQueryItem(name: "f", value: ",,,,,"), URLQueryItem(name: "p", value: "1")]
        var request = URLRequest(url: list.url!)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        let wanted = results.prefix(limit * 2).compactMap { item -> (Int, URL, URL, String, URL?)? in
            guard let thumb = (item["thumbnail"] as? String).flatMap(URL.init(string:)),
                  let page = (item["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (0, thumb, page, item["title"] as? String ?? "", (item["image"] as? String).flatMap(URL.init(string:)))
        }.enumerated().map { ($0.offset, $0.element.1, $0.element.2, $0.element.3, $0.element.4) }
        let found = await withTaskGroup(of: (Int, Picture?).self) { group in
            for (rank, thumb, page, title, full) in wanted {
                group.addTask {
                    guard let data = try? await fetchData(thumb, limit: 3_000_000),
                          let small = smallJPEG(data) else { return (rank, nil) }
                    return (rank, Picture(title: decodeEntities(title), page: page, thumbnail: small, full: full))
                }
            }
            var all: [(Int, Picture)] = []
            for await (rank, picture) in group { if let picture { all.append((rank, picture)) } }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return Array(found.prefix(limit))
    }

    /// The pages of an ordinary search, each page's own main picture.
    private static func pagePictures(for query: String, limit: Int) async -> [Picture] {
        guard let results = try? await results(for: query) else { return [] }
        let pages = results.prefix(10).compactMap { result -> (Int, URL, String)? in
            guard let url = URL(string: result.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return (0, url, result.title)
        }.enumerated().map { ($0.offset, $0.element.1, $0.element.2) }
        let found = await withTaskGroup(of: (Int, Picture?).self) { group in
            for (rank, page, title) in pages {
                group.addTask { (rank, await picture(on: page, title: title)) }
            }
            var all: [(Int, Picture)] = []
            for await (rank, picture) in group { if let picture { all.append((rank, picture)) } }
            return all.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var seen = Set<Data>()
        return Array(found.filter { seen.insert($0.thumbnail).inserted }.prefix(limit))
    }

    /// The page's main picture, downloaded and made small; nil if it has none.
    private static func picture(on page: URL, title: String) async -> Picture? {
        guard let host = page.host, await !isLocal(host),
              let html = try? await fetch(page, publicOnly: true) else { return nil }
        let patterns = [
            #"(?i)<meta[^>]+(?:property|name)\s*=\s*["'](?:og:image(?::url|:secure_url)?|twitter:image(?::src)?)["'][^>]*content\s*=\s*["']([^"']+)["']"#,
            #"(?i)<meta[^>]+content\s*=\s*["']([^"']+)["'][^>]*(?:property|name)\s*=\s*["'](?:og:image(?::url|:secure_url)?|twitter:image(?::src)?)["']"#,
        ]
        guard let raw = patterns.lazy.compactMap({ matches($0, in: html).first?.first }).first,
              let address = URL(string: decodeEntities(raw), relativeTo: page)?.absoluteURL,
              ["http", "https"].contains(address.scheme?.lowercased() ?? ""),
              let imageHost = address.host, await !isLocal(imageHost),
              let data = try? await fetchData(address, limit: 6_000_000),
              let thumbnail = smallJPEG(data) else { return nil }
        return Picture(title: decodeEntities(title), page: page, thumbnail: thumbnail, full: address)
    }

    /// Saves a picture into Downloads: the full-size one when it can be
    /// fetched (a public address, at most 25 MB, really a picture), else
    /// the thumbnail. Named after its title. Nil if nothing could be saved.
    static func save(_ picture: Picture) async -> URL? {
        var data = picture.thumbnail
        var ext = "jpg"
        if let full = picture.full, ["http", "https"].contains(full.scheme?.lowercased() ?? ""),
           let host = full.host, await !isLocal(host),
           let fetched = try? await fetchData(full, limit: 25_000_000),
           let source = CGImageSourceCreateWithData(fetched as CFData, nil),
           CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source) as String? {
            let known = ["public.jpeg": "jpg", "public.png": "png", "org.webmproject.webp": "webp",
                         "com.compuserve.gif": "gif", "public.heic": "heic", "public.tiff": "tiff"]
            if let found = known[type] {
                data = fetched
                ext = found
            }
        }
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = picture.title.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|\n"))
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = picture.page.host ?? "Picture" }
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(copy)").appendingPathExtension(ext)
            copy += 1
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// A body as bytes, at most `limit` (pictures).
    private static func fetchData(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: PublicRedirects())
        if let http = response as? HTTPURLResponse, !(200 ..< 400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }

    /// Decoded at 360 px on the long side, as JPEG; nil if it isn't a
    /// picture or is too small to be the page's real one (icons, pixels).
    private static func smallJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 360,
              ] as CFDictionary),
              image.width >= 120, image.height >= 90 else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    // MARK: - Helpers

    /// The body, at most 2 MB — read as it streams, so a huge download
    /// stops there instead of arriving whole and being trimmed.
    /// `publicOnly`: redirects to a local address are refused too.
    private static func fetch(_ url: URL, publicOnly: Bool = false) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (bytes, response) = try await session.bytes(for: request, delegate: publicOnly ? PublicRedirects() : nil)
        if let http = response as? HTTPURLResponse, !(200 ..< 400).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        var data = Data()
        data.reserveCapacity(64_000)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 2_000_000 { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Follows a redirect only to a public http(s) address, judged by the
    /// address itself (no lookup here; `read` resolved the first host).
    private final class PublicRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, let host = url.host, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  !WebAccess.isLocalName(host) else {
                ActivityLog.write(.blocked, "read_webpage: redirect to \(request.url?.absoluteString ?? "?") refused")
                return nil
            }
            return request
        }
    }

    /// Whether a host is this Mac or the local network — by its name, or by
    /// any address it resolves to (a public name can point at 192.168.x).
    private static func isLocal(_ host: String) async -> Bool {
        if isLocalName(host) { return true }
        return await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
            defer { freeaddrinfo(list) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let entry = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0, isLocalName(String(cString: buffer)) {
                    return true
                }
                cursor = entry.pointee.ai_next
            }
            return false
        }.value
    }

    /// localhost, *.local, and private, loopback, link-local and unique-local
    /// addresses (IPv4 and IPv6), written as they are.
    nonisolated static func isLocalName(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".internal") {
            return true
        }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
            case (172, 16...31), (100, 64...127): return true
            default: return false
            }
        }
        if name.contains(":") {
            return name == "::1" || name == "::" || name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd")
                || name.hasPrefix("::ffff:") && isLocalName(String(name.dropFirst(7)))
        }
        return false
    }

    /// Capture groups of every match.
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1 ..< match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// Tags removed, entities decoded, whitespace tidied.
    private static func plainText(_ html: String, keepLines: Bool = false) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        if keepLines {
            text = text.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        } else {
            text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML and XML entities. Also used by `TextExtractor` for Office XML.
    /// `&amp;` goes last, so "&amp;lt;" stays the literal text "&lt;".
    static func decodeEntities(_ text: String) -> String {
        var out = text
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'",
                     "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (entity, character) in named { out = out.replacingOccurrences(of: entity, with: character) }
        // Numeric ones: &#8217; and &#x2019;
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = out as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                if let value = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(value) {
                    result += String(Character(scalar))
                } else {
                    result += ns.substring(with: match.range)
                }
                last = match.range.location + match.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
