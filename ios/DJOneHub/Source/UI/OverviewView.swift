import SwiftUI

struct OverviewView: View {
    @ObservedObject var api: APIClient
    @State private var status: ModuleStatus?
    @State private var isLoading = false
    @State private var lastError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Module status
                statusCard

                // Signal strength
                signalCard

                // Network info
                networkCard

                // SIM info
                simCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .refreshable { await loadStatus() }
        .onAppear { Task { await loadStatus() } }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("模块状态")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.appSecondary)
                    .textCase(.uppercase)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            if let status = status {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    infoItem(label: "运营商", value: status.operator_name ?? "—")
                    infoItem(label: "网络", value: status.network_mode ?? "—")
                    infoItem(label: "注册", value: status.reg_status_text ?? "—")
                    infoItem(label: "双工", value: status.network_duplex ?? "—")
                }
            } else {
                Text("正在加载...")
                    .font(.system(size: 14))
                    .foregroundColor(.appSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
        .padding(16)
        .background(Color.appFill.opacity(0.5))
        .cornerRadius(16)
    }

    // MARK: - Signal Card

    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("信号强度")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.appSecondary)
                .textCase(.uppercase)

            if let status = status {
                HStack(spacing: 20) {
                    VStack(spacing: 4) {
                        Text("\(status.signal_dbm ?? 0)")
                            .font(.system(size: 32, weight: .light, design: .monospaced))
                            .foregroundColor(.appPrimary)
                        Text("dBm")
                            .font(.system(size: 11))
                            .foregroundColor(.appSecondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        signalBar(value: status.signal_dbm ?? -100, min: -120, max: -50)
                        Text(signalQuality(status.signal_dbm ?? -100))
                            .font(.system(size: 12))
                            .foregroundColor(signalColor(status.signal_dbm ?? -100))
                    }
                }

                if let band = status.radio_band, !band.isEmpty {
                    HStack {
                        Text("频段: \(band)")
                            .font(.system(size: 12))
                            .foregroundColor(.appSecondary)
                        if let channel = status.radio_channel, channel > 0 {
                            Text("信道: \(channel)")
                                .font(.system(size: 12))
                                .foregroundColor(.appSecondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color.appFill.opacity(0.5))
        .cornerRadius(16)
    }

    // MARK: - Network Card

    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网络信息")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.appSecondary)
                .textCase(.uppercase)

            if let status = status {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    infoItem(label: "APN", value: status.apn ?? "—")
                    infoItem(label: "USB网络", value: status.usbnet_mode == 1 ? "已开启" : "未开启")
                    infoItem(label: "IMS状态", value: imsStatusText(status.ims_status ?? 0))
                    infoItem(label: "PS附着", value: status.ps_attached == true ? "是" : "否")
                }
            }
        }
        .padding(16)
        .background(Color.appFill.opacity(0.5))
        .cornerRadius(16)
    }

    // MARK: - SIM Card

    private var simCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SIM 卡片")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.appSecondary)
                .textCase(.uppercase)

            if let status = status {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    infoItem(label: "SIM状态", value: status.sim_inserted == true ? "已插入" : "未插入")
                    infoItem(label: "ICCID", value: maskedICCID(status.iccid))
                    infoItem(label: "IMSI", value: maskedIMSI(status.imsi))
                    infoItem(label: "IMEI", value: maskedIMEI(status.imei))
                }
            }
        }
        .padding(16)
        .background(Color.appFill.opacity(0.5))
        .cornerRadius(16)
    }

    // MARK: - Helpers

    private func infoItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.appSecondary)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.appPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.systemGray6).opacity(0.3))
        .cornerRadius(10)
    }

    private func signalBar(value: Int, min minVal: Int, max maxVal: Int) -> some View {
        GeometryReader { geo in
            let progress = CGFloat(Swift.max(minVal, Swift.min(maxVal, value)) - minVal) / CGFloat(maxVal - minVal)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(.systemGray5))
                    .frame(height: 6)
                RoundedRectangle(cornerRadius: 3)
                    .fill(signalColor(value))
                    .frame(width: geo.size.width * progress, height: 6)
            }
        }
        .frame(height: 6)
    }

    private func signalQuality(_ dbm: Int) -> String {
        switch dbm {
        case -50...0: return "极好"
        case -70...(-50): return "良好"
        case -85...(-70): return "一般"
        case -100...(-85): return "较差"
        default: return "极差"
        }
    }

    private func signalColor(_ dbm: Int) -> Color {
        switch dbm {
        case -70...0: return .green
        case -85...(-70): return .yellow
        case -100...(-85): return .orange
        default: return .red
        }
    }

    private func imsStatusText(_ status: Int) -> String {
        switch status {
        case 0: return "未注册"
        case 1: return "已注册"
        case 2: return "注册中"
        default: return "未知"
        }
    }

    private func maskedICCID(_ iccid: String?) -> String {
        guard let iccid = iccid, iccid.count > 8 else { return "—" }
        return String(iccid.prefix(4)) + "****" + String(iccid.suffix(4))
    }

    private func maskedIMSI(_ imsi: String?) -> String {
        guard let imsi = imsi, imsi.count > 6 else { return "—" }
        return String(imsi.prefix(3)) + "****" + String(imsi.suffix(4))
    }

    private func maskedIMEI(_ imei: String?) -> String {
        guard let imei = imei, !imei.isEmpty else { return "—" }
        return imei
    }

    // MARK: - Load

    private func loadStatus() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await api.fetchStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
