import Foundation

// MARK: - Models

struct ModuleStatus: Codable {
    let imei: String?
    let firmware: String?
    let iccid: String?
    let imsi: String?
    let operator_name: String?
    let sim_inserted: Bool?
    let signal_dbm: Int?
    let signal_rsrp: Int?
    let signal_rsrq: Int?
    let radio_band: String?
    let radio_channel: Int?
    let reg_status: Int?
    let reg_status_text: String?
    let ps_attached: Bool?
    let lac: String?
    let cell_id: String?
    let apn: String?
    let ims_status: Int?
    let network_mode: String?
    let network_duplex: String?
    let usbnet_mode: Int?

    enum CodingKeys: String, CodingKey {
        case imei, firmware, iccid, imsi, sim_inserted, signal_dbm
        case signal_rsrp, signal_rsrq, radio_band, radio_channel
        case reg_status, reg_status_text, ps_attached, lac, cell_id, apn
        case ims_status, network_mode, network_duplex, usbnet_mode
        case operator_name = "operator"
    }
}

struct SMSMessage: Codable, Identifiable {
    var id: String { "\(sender)_\(timestamp)_\(content.prefix(20))" }
    let sender: String
    let content: String
    let timestamp: String
}

struct SMSConversation: Identifiable {
    var id: String { number }
    let number: String
    var messages: [SMSMessage]
    var lastMessage: SMSMessage { messages.last! }
    var unread: Bool = false
}

struct NetworkInfo: Codable {
    let usbnet_mode: String?
    let usbcfg: String?
    let pdp_contexts: [PDPContext]?
}

struct PDPContext: Codable {
    let id: Int?
    let pdn: String?
    let apn: String?
}

struct GPSInfo: Codable {
    let enabled: Bool?
    let last_checked: String?
    let last_error: String?
    let last_fix: GPSFix?
}

struct GPSFix: Codable {
    let lat: Double?
    let lon: Double?
    let alt: Double?
    let speed: Double?
    let course: Double?
    let satellites: Int?
    let hdop: Double?
    let time: String?
}

struct ESIMProfiles: Codable {
    let chip: ESIMChip?
    let profiles: [ESIMProfile]?
}

struct ESIMChip: Codable {
    let eid: String?
    let firmware: String?
}

struct ESIMProfile: Codable {
    let iccid: String?
    let state: String?
    let profile_name: String?
    let nickname: String?
    let provider: String?
    let profileClass: String?

    enum CodingKeys: String, CodingKey {
        case iccid, state, profile_name, nickname, provider
        case profileClass = "class"
    }
}

struct ATResponse: Codable {
    let response: String?
    let error: String?
}

struct SMSSendResponse: Codable {
    let sent: Bool?
    let segments: Int?
    let error: String?
}

// MARK: - API Client

class APIClient: ObservableObject {
    let baseURL: String

    init(host: String, port: Int) {
        self.baseURL = "http://\(host):\(port)"
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        guard let url = URL(string: "\(baseURL)\(path)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Status

    func fetchStatus() async throws -> ModuleStatus {
        return try await get("/api/status")
    }

    // MARK: - SMS

    func fetchSMS() async throws -> [SMSMessage] {
        return try await get("/api/sms")
    }

    func sendSMS(phone: String, message: String) async throws -> SMSSendResponse {
        return try await post("/api/sms/send", body: ["phone": phone, "message": message])
    }

    func clearSMS() async throws -> ATResponse {
        return try await post("/api/sms/clear", body: [:])
    }

    // MARK: - Network

    func fetchNetwork() async throws -> NetworkInfo {
        return try await get("/api/network")
    }

    // MARK: - GPS

    func fetchGPS() async throws -> GPSInfo {
        return try await get("/api/gps")
    }

    func toggleGPS(enable: Bool) async throws -> ATResponse {
        return try await post("/api/gps/toggle", body: ["enable": enable])
    }

    // MARK: - eSIM

    func fetchESIM() async throws -> ESIMProfiles {
        return try await get("/api/esim/profiles")
    }

    // MARK: - AT

    func sendAT(_ command: String) async throws -> ATResponse {
        return try await post("/api/at", body: ["command": command])
    }
}
