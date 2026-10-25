import SwiftUI

struct OverviewView: View {
    @ObservedObject var api: APIClient
    @State private var status: ModuleStatus?
    @State private var isLoading = false
    @State private var lastError: String?

    var body: some View {
        // 与「更多」页排版语言统一：原生 List + insetGrouped Section 分组
        List {
            Section {
                if let status = status {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        infoItem(label: "运营商", value: status.operator_name ?? "—")
                        infoItem(label: "网络", value: status.network_mode ?? "—")
                        infoItem(label: "注册", value: status.reg_status_text ?? "—")
                        infoItem(label: "双工", value: status.network_duplex ?? "—")
                    }
                    .padding(.vertical, 4)
                } else if isLoading {
                    HStack { Spacer(); ProgressView().scaleEffect(0.8); Spacer() }
                    .padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                } else {
                    Text("正在加载...")
                        .font(.system(size: 14))
                        .foregroundColor(.appSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("模块状态")
            }

            Section {
                if let status = status {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        // 信号强度：数值（信号色着色）+ 图形化进度条
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(status.signal_dbm ?? 0) dBm")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(signalColor(status.signal_dbm ?? -100))
                            signalBar(value: status.signal_dbm ?? -100, min: -120, max: -50)
                            Text("信号强度")
                                .font(.system(size: 11))
                                .foregroundColor(.appSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(.systemGray6).opacity(0.3))
                        .cornerRadius(10)

                        infoItem(label: "信号质量", value: signalQuality(status.signal_dbm ?? -100), valueColor: signalColor(status.signal_dbm ?? -100))
                        infoItem(label: "频段", value: status.radio_band ?? "—")
                        infoItem(label: "信道", value: (status.radio_channel ?? 0) > 0 ? "\(status.radio_channel!)" : "—")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("信号强度")
            }

            Section {
                if let status = status {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        infoItem(label: "APN", value: status.apn ?? "—")
                        infoItem(label: "USB网络", value: status.usbnet_mode == 1 ? "已开启" : "未开启")
                        infoItem(label: "IMS状态", value: imsStatusText(status.ims_status ?? 0))
                        infoItem(label: "PS附着", value: status.ps_attached == true ? "是" : "否")
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("网络信息")
            }

            Section {
                if let status = status {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        infoItem(label: "SIM状态", value: status.sim_inserted == true ? "已插入" : "未插入")
                        infoItem(label: "ICCID", value: maskedICCID(status.iccid))
                        infoItem(label: "IMSI", value: maskedIMSI(status.imsi))
                        infoItem(label: "IMEI", value: maskedIMEI(status.imei))
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("SIM 卡片")
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .refreshable { await loadStatus() }
        .onAppear { Task { await loadStatus() } }
        // WebSocket 重连成功后自动重拉状态（修复：断线重连后运营商等信息不刷新）
        .onReceive(NotificationCenter.default.publisher(for: .djonehubSignalingDidConnect)) { _ in
            Task { await loadStatus() }
        }
    }

    // MARK: - Status Card

    // MARK: - Helpers

    private func infoItem(label: String, value: String, valueColor: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.appSecondary)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(valueColor ?? .appPrimary)
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
