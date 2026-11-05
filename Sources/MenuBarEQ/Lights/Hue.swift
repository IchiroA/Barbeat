import Foundation
import Network
import CryptoKit
import Security

// Philips Hue: pairing, entertainment areas, saving and restoring the lights, and the real-time stream.
// Only Entertainment areas (made in the Hue app) can be streamed to; rooms and zones can't.

/// The keys a bridge hands out when you press its button. Kept in the Keychain.
struct HueCredentials: Codable, Equatable {
    var username: String
    var clientKey: String

    static func load(bridge: String) -> HueCredentials? {
        guard let text = Keychain.get(account: bridge) else { return nil }
        return try? JSONDecoder().decode(HueCredentials.self, from: Data(text.utf8))
    }

    func save(bridge: String) {
        guard let data = try? JSONEncoder().encode(self), let text = String(data: data, encoding: .utf8) else { return }
        Keychain.set(text, account: bridge)
    }

    static func delete(bridge: String) { Keychain.delete(account: bridge) }
}

/// An entertainment area: its lights' channels and where they sit in the room (-1 left ... +1 right).
struct HueArea: Equatable, Identifiable {
    struct Channel: Equatable {
        var id: Int
        var x: Double, y: Double, z: Double
    }

    var id: String
    var name: String
    var active: Bool
    /// Who is streaming to it right now (an application ID), if anyone.
    var streamer: String?
    var channels: [Channel]
    var lightIDs: [String]

    var slots: [LightSlot] { channels.map { LightSlot(channel: $0.id, x: $0.x, y: $0.y) } }
}

/// One light as it was before Barbeat took over.
struct HueLightState: Codable, Equatable {
    var id: String
    var on: Bool
    var brightness: Double?
    var x: Double?, y: Double?
    var mirek: Int?
    var gradient: [[Double]]?

    /// Close enough to count as restored.
    func matches(_ other: HueLightState) -> Bool {
        guard on == other.on else { return false }
        guard on else { return true }
        if let a = brightness, let b = other.brightness, abs(a - b) > 3 { return false }
        if let a = mirek, let b = other.mirek { return abs(a - b) <= 6 }
        if mirek != nil || other.mirek != nil { return false }
        if let ax = x, let ay = y, let bx = other.x, let by = other.y {
            return abs(ax - bx) < 0.02 && abs(ay - by) < 0.02
        }
        return true
    }

    /// The CLIP v2 body that puts the light back. `full` false sends only on/off (for lights that refuse the rest).
    func body(full: Bool = true, gradient withGradient: Bool = true) -> [String: Any] {
        var body: [String: Any] = ["on": ["on": on], "dynamics": ["duration": 400]]
        guard full else { return body }
        if let brightness { body["dimming"] = ["brightness": min(100, max(1, brightness))] }
        if let mirek {
            body["color_temperature"] = ["mirek": mirek]
        } else if let x, let y {
            body["color"] = ["xy": ["x": x, "y": y]]
        }
        if withGradient, let gradient, gradient.count >= 2 {
            body["gradient"] = ["points": gradient.map { ["color": ["xy": ["x": $0[0], "y": $0[1]]]] }]
        }
        return body
    }
}

/// A scene that was showing, so a dynamic scene can be started again.
struct HueSceneRef: Codable, Equatable {
    var id: String
    /// "active" or "dynamic_palette".
    var action: String
    var lights: [String]
}

/// Everything needed to put an area's lights back. Saved to disk while Barbeat holds the lights,
/// so a crash or force-quit can still be undone on the next launch.
struct HueSnapshot: Codable {
    var bridge: String
    var area: String
    var lights: [HueLightState]
    var scenes: [HueSceneRef]
    var taken: Date

    private static func url(bridge: String) -> URL? {
        let id = Bundle.main.bundleIdentifier ?? "com.ia.MenuBarEQ"
        let folder = id == "com.ia.MenuBarEQ" ? "Barbeat" : id
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("hue-restore-\(bridge).json")
    }

    static func load(bridge: String) -> HueSnapshot? {
        guard let url = url(bridge: bridge), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HueSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.url(bridge: bridge) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

    static func delete(bridge: String) {
        if let url = url(bridge: bridge) { try? FileManager.default.removeItem(at: url) }
    }
}

enum HueError: LocalizedError {
    case unreachable(String)
    case unauthorized
    case certificateChanged
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let host): return "Can't reach the Hue Bridge at \(host)."
        case .unauthorized: return "The bridge no longer knows Barbeat. Remove it and pair again."
        case .certificateChanged: return "The bridge's certificate changed. Remove it and pair again if you replaced the bridge."
        case .message(let text): return text
        }
    }
}

/// Talks to one bridge over HTTPS. The bridge's certificate is remembered the first time (trust on first use)
/// and checked every time after that.
final class HueClient: NSObject, URLSessionDelegate {
    let host: String
    private let lock = NSLock()
    private var pinned: String?
    private var mismatch = false

    init(host: String, pin: String?) {
        self.host = host
        pinned = pin
    }

    /// The certificate fingerprint, once known.
    var pin: String? {
        lock.lock(); defer { lock.unlock() }
        return pinned
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func invalidate() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        lock.lock()
        if pinned == nil { pinned = fingerprint }
        let ok = pinned == fingerprint
        mismatch = !ok
        lock.unlock()
        if ok {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    @discardableResult
    func call(_ method: String, _ path: String, key: String? = nil, body: Any? = nil) async throws -> (json: Any?, response: HTTPURLResponse) {
        guard let url = URL(string: "https://\(host)\(path)") else { throw HueError.message("“\(host)” isn't a valid address.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let key { request.setValue(key, forHTTPHeaderField: "hue-application-key") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let changed = lock.withLock { mismatch }
            throw changed ? HueError.certificateChanged : HueError.unreachable(host)
        }
        guard let http = response as? HTTPURLResponse else { throw HueError.unreachable(host) }
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        if http.statusCode == 401 || http.statusCode == 403 { throw HueError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw HueError.message(Self.errorText(json) ?? "The bridge answered with error \(http.statusCode).")
        }
        return (json, http)
    }

    /// PUT that also fails when the bridge lists errors in an otherwise fine answer.
    private func put(_ path: String, key: String, body: [String: Any]) async throws {
        let (json, _) = try await call("PUT", path, key: key, body: body)
        if let text = Self.errorText(json) { throw HueError.message(text) }
    }

    private static func errorText(_ json: Any?) -> String? {
        guard let errors = (json as? [String: Any])?["errors"] as? [[String: Any]], let first = errors.first else { return nil }
        return first["description"] as? String ?? "The bridge refused the request."
    }

    private static func dataArray(_ json: Any?) -> [[String: Any]] {
        (json as? [String: Any])?["data"] as? [[String: Any]] ?? []
    }

    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

    // MARK: - Pairing

    /// The bridge's ID and name (no key needed).
    func bridgeInfo() async throws -> (id: String, name: String) {
        let (json, _) = try await call("GET", "/api/0/config")
        guard let config = json as? [String: Any], let id = config["bridgeid"] as? String else {
            throw HueError.message("That address doesn't look like a Hue Bridge.")
        }
        return (id.lowercased(), config["name"] as? String ?? "Hue Bridge")
    }

    /// Asks for keys. Nil means the bridge's button hasn't been pressed yet.
    func pair(deviceType: String) async throws -> HueCredentials? {
        let (json, _) = try await call("POST", "/api", body: ["devicetype": deviceType, "generateclientkey": true])
        guard let first = (json as? [[String: Any]])?.first else { throw HueError.message("The bridge gave an unexpected answer.") }
        if let success = first["success"] as? [String: Any], let username = success["username"] as? String,
           let clientKey = success["clientkey"] as? String {
            return HueCredentials(username: username, clientKey: clientKey)
        }
        if let error = first["error"] as? [String: Any] {
            if (error["type"] as? Int) == 101 { return nil }   // link button not pressed
            throw HueError.message(error["description"] as? String ?? "The bridge refused to pair.")
        }
        throw HueError.message("The bridge gave an unexpected answer.")
    }

    /// The application ID, which is the identity for the encrypted stream.
    func applicationID(key: String) async throws -> String {
        let (_, response) = try await call("GET", "/auth/v1", key: key)
        guard let id = response.value(forHTTPHeaderField: "hue-application-id"), !id.isEmpty else {
            throw HueError.message("The bridge's software is too old for streaming. Update it in the Hue app.")
        }
        return id
    }

    // MARK: - Entertainment areas

    func areas(key: String) async throws -> [HueArea] {
        let (json, _) = try await call("GET", "/clip/v2/resource/entertainment_configuration", key: key)
        var areas: [HueArea] = []
        var members: [String: [String]] = [:]
        for item in Self.dataArray(json) {
            guard let id = item["id"] as? String else { continue }
            let name = (item["metadata"] as? [String: Any])?["name"] as? String ?? "Entertainment area"
            var channels: [HueArea.Channel] = []
            var services: [String] = []
            for channel in item["channels"] as? [[String: Any]] ?? [] {
                guard let channelID = channel["channel_id"] as? Int else { continue }
                let p = channel["position"] as? [String: Any]
                channels.append(HueArea.Channel(id: channelID, x: Self.number(p?["x"]) ?? 0,
                                                y: Self.number(p?["y"]) ?? 0, z: Self.number(p?["z"]) ?? 0))
                for member in channel["members"] as? [[String: Any]] ?? [] {
                    if let rid = (member["service"] as? [String: Any])?["rid"] as? String { services.append(rid) }
                }
            }
            let lights = (item["light_services"] as? [[String: Any]] ?? []).compactMap { $0["rid"] as? String }
            members[id] = services
            areas.append(HueArea(id: id, name: name, active: (item["status"] as? String) == "active",
                                 streamer: (item["active_streamer"] as? [String: Any])?["rid"] as? String,
                                 channels: channels.sorted { $0.id < $1.id }, lightIDs: lights))
        }
        // Older bridge software lists only the channels' entertainment services: look up their lights.
        if areas.contains(where: { $0.lightIDs.isEmpty && !(members[$0.id] ?? []).isEmpty }) {
            let (json, _) = try await call("GET", "/clip/v2/resource/entertainment", key: key)
            var renderer: [String: String] = [:]
            for item in Self.dataArray(json) {
                if let id = item["id"] as? String,
                   let light = (item["renderer_reference"] as? [String: Any])?["rid"] as? String { renderer[id] = light }
            }
            for i in areas.indices where areas[i].lightIDs.isEmpty {
                var seen = Set<String>()
                areas[i].lightIDs = (members[areas[i].id] ?? []).compactMap { renderer[$0] }.filter { seen.insert($0).inserted }
            }
        }
        return areas.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setStreaming(_ on: Bool, area: String, key: String) async throws {
        try await put("/clip/v2/resource/entertainment_configuration/\(area)", key: key, body: ["action": on ? "start" : "stop"])
    }

    // MARK: - Lights and scenes

    func lights(key: String) async throws -> [String: HueLightState] {
        let (json, _) = try await call("GET", "/clip/v2/resource/light", key: key)
        var result: [String: HueLightState] = [:]
        for item in Self.dataArray(json) {
            guard let id = item["id"] as? String else { continue }
            let on = (item["on"] as? [String: Any])?["on"] as? Bool ?? false
            let brightness = Self.number((item["dimming"] as? [String: Any])?["brightness"])
            let xy = (item["color"] as? [String: Any])?["xy"] as? [String: Any]
            let temperature = item["color_temperature"] as? [String: Any]
            let mirek = (temperature?["mirek_valid"] as? Bool ?? false) ? (temperature?["mirek"] as? NSNumber)?.intValue : nil
            let points = ((item["gradient"] as? [String: Any])?["points"] as? [[String: Any]])?.compactMap { point -> [Double]? in
                guard let xy = (point["color"] as? [String: Any])?["xy"] as? [String: Any],
                      let x = Self.number(xy["x"]), let y = Self.number(xy["y"]) else { return nil }
                return [x, y]
            }
            result[id] = HueLightState(id: id, on: on, brightness: brightness,
                                       x: mirek == nil ? Self.number(xy?["x"]) : nil,
                                       y: mirek == nil ? Self.number(xy?["y"]) : nil,
                                       mirek: mirek, gradient: (points?.count ?? 0) >= 2 ? points : nil)
        }
        return result
    }

    /// Scenes currently showing on any of these lights.
    func activeScenes(lights: Set<String>, key: String) async throws -> [HueSceneRef] {
        let (json, _) = try await call("GET", "/clip/v2/resource/scene", key: key)
        return Self.dataArray(json).compactMap { item in
            guard let id = item["id"] as? String,
                  let active = (item["status"] as? [String: Any])?["active"] as? String, active != "inactive" else { return nil }
            let targets = (item["actions"] as? [[String: Any]] ?? []).compactMap {
                ($0["target"] as? [String: Any])?["rid"] as? String
            }
            guard !lights.isDisjoint(with: targets) else { return nil }
            return HueSceneRef(id: id, action: active == "dynamic_palette" ? "dynamic_palette" : "active", lights: targets)
        }
    }

    func recall(_ scene: HueSceneRef, key: String) async throws {
        try await put("/clip/v2/resource/scene/\(scene.id)", key: key, body: ["recall": ["action": scene.action]])
    }

    /// Puts one light back, falling back to less if the light refuses part of it (e.g. color while off).
    func restore(_ state: HueLightState, key: String) async throws {
        let path = "/clip/v2/resource/light/\(state.id)"
        do {
            try await put(path, key: key, body: state.body())
        } catch HueError.message {
            do {
                try await put(path, key: key, body: state.body(gradient: false))
            } catch HueError.message {
                try await put(path, key: key, body: state.body(full: false))
            }
        }
    }

    func identify(light: String, key: String) async throws {
        try await put("/clip/v2/resource/light/\(light)", key: key, body: ["identify": ["action": "identify"]])
    }
}

/// The encrypted real-time stream to an entertainment area (DTLS 1.2 with a pre-shared key, UDP port 2100).
final class HueStream {
    static let port: NWEndpoint.Port = 2100

    private let connection: NWConnection
    private let areaID: [UInt8]
    private var sequence: UInt8 = 0
    private var timeout: DispatchWorkItem?
    private var done = false
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init?(host: String, identity: String, clientKey: String, areaID: String) {
        guard let key = Data(hex: clientKey), !identity.isEmpty, areaID.utf8.count == 36 else { return nil }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .DTLSv12)
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let pskIdentity = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, pskIdentity as __DispatchData)
        // The one cipher suite the bridge speaks: TLS_PSK_WITH_AES_128_GCM_SHA256.
        if let suite = tls_ciphersuite_t(rawValue: 0x00A8) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        let parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
        let address = host.split(separator: ":").first.map(String.init) ?? host
        connection = NWConnection(host: NWEndpoint.Host(address), port: Self.port, using: parameters)
        self.areaID = Array(areaID.utf8)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.done else { return }
            switch state {
            case .ready:
                self.timeout?.cancel()
                self.onReady?()
            case .failed(let error):
                self.fail("The stream to the bridge failed (\(error.localizedDescription)).")
            case .waiting(let error):
                // Waiting on a handshake that won't finish; the timeout below gives up.
                if case .tls = error { self.fail("The bridge refused the encrypted stream. Try pairing again.") }
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.fail("The bridge didn't answer the encrypted stream.")
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        connection.start(queue: .main)
    }

    private func fail(_ message: String) {
        guard !done else { return }
        done = true
        timeout?.cancel()
        connection.cancel()
        onFailure?(message)
    }

    func send(_ channels: [(id: Int, color: LightColor)]) {
        guard !done else { return }
        sequence &+= 1
        connection.send(content: Self.message(areaID: areaID, sequence: sequence, channels: channels),
                        completion: .idempotent)
    }

    func cancel() {
        done = true
        timeout?.cancel()
        connection.cancel()
    }

    /// A HueStream v2 message in XY + brightness color space (at most 20 channels).
    static func message(areaID: [UInt8], sequence: UInt8, channels: [(id: Int, color: LightColor)]) -> Data {
        var bytes: [UInt8] = Array("HueStream".utf8)
        bytes += [0x02, 0x00, sequence, 0x00, 0x00, 0x01, 0x00]
        bytes += areaID
        for (id, color) in channels.prefix(20) {
            let (x, y, brightness) = xyBrightness(color)
            bytes.append(UInt8(clamping: id))
            for value in [x, y, brightness] {
                let v = UInt16((min(1, max(0, value)) * 65535).rounded())
                bytes += [UInt8(v >> 8), UInt8(v & 0xFF)]
            }
        }
        return Data(bytes)
    }

    /// sRGB color to CIE xy (the wide-gamut conversion Hue recommends), plus brightness.
    /// The color's own darkness (e.g. a deep red) dims the light too, as it does on screen.
    static func xyBrightness(_ c: LightColor) -> (Double, Double, Double) {
        func linear(_ v: Float) -> Double {
            let v = Double(min(1, max(0, v)))
            return v > 0.04045 ? pow((v + 0.055) / 1.055, 2.4) : v / 12.92
        }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let X = r * 0.664511 + g * 0.154324 + b * 0.162028
        let Y = r * 0.283881 + g * 0.668433 + b * 0.047685
        let Z = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = X + Y + Z
        let value = Double(max(c.r, c.g, c.b))
        guard sum > 1e-6 else { return (0.3127, 0.3290, 0) }
        return (X / sum, Y / sum, Double(c.brightness) * min(1, value))
    }
}

extension Data {
    /// Bytes from a hex string like "a1b2c3".
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        self.init(bytes)
    }
}

// MARK: - Finding bridges

/// Finds Hue Bridges with Bonjour, falling back to Philips' discovery service.
final class HueDiscovery {
    struct Bridge: Identifiable, Equatable {
        var host: String
        var name: String
        var id: String { host }
    }

    var onUpdate: (([Bridge]) -> Void)?
    private(set) var bridges: [Bridge] = []
    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []

    func start() {
        stop()
        let browser = NWBrowser(for: .bonjour(type: "_hue._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results { self?.resolve(result.endpoint) }
        }
        browser.start(queue: .main)
        self.browser = browser
        // No answer over Bonjour after a few seconds: ask Philips' discovery service.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.browser != nil, self.bridges.isEmpty else { return }
            self.askCloud()
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolving.forEach { $0.cancel() }
        resolving.removeAll()
    }

    /// Connects briefly to learn the bridge's IPv4 address.
    private func resolve(_ endpoint: NWEndpoint) {
        guard case let .service(name, _, _, _) = endpoint else { return }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                    var address = "\(host)"
                    if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                    self.add(Bridge(host: address, name: name))
                }
                connection.cancel()
            case .failed, .cancelled:
                self.resolving.removeAll { $0 === connection }
            default:
                break
            }
        }
        resolving.append(connection)
        connection.start(queue: .main)
    }

    private func askCloud() {
        guard let url = URL(string: "https://discovery.meethue.com/") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                for item in list {
                    guard let ip = item["internalipaddress"] as? String else { continue }
                    let id = (item["id"] as? String ?? "").uppercased()
                    self?.add(Bridge(host: ip, name: id.isEmpty ? "Hue Bridge" : "Hue Bridge \(id.suffix(6))"))
                }
            }
        }.resume()
    }

    private func add(_ bridge: Bridge) {
        guard !bridges.contains(where: { $0.host == bridge.host }) else { return }
        bridges.append(bridge)
        onUpdate?(bridges)
    }
}
