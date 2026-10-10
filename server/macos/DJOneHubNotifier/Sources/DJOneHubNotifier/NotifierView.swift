import SwiftUI

struct NotifierView: View {
    @EnvironmentObject private var contacts: ContactStore
    let content: PanelContent
    let onReject: () -> Void
    let onAnswer: () -> Void
    let onOpen: () -> Void
    var onSizeChange: ((CGSize) -> Void)?

    var body: some View {
        Group {
            switch content {
            case let .incoming(number, startedAt):
                incomingView(number: number, startedAt: startedAt)
            case let .sms(sender, preview, code):
                smsView(sender: sender, preview: preview, code: code)
            case let .missed(number, startedAt):
                missedView(number: number, startedAt: startedAt)
            case let .error(message):
                messageView(title: "DJOneHub 暂时离线", detail: message, symbol: "exclamationmark.triangle.fill")
            case .idle:
                EmptyView()
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.24), lineWidth: 0.8)
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onSizeChange?(geo.size) }
                    .onChange(of: geo.size) { newSize in
                        onSizeChange?(newSize)
                    }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 20, y: 8)
    }

    private func incomingView(number: String, startedAt: Date) -> some View {
        let contact = contacts.contact(for: number)
        let displayName = contact?.name
        let title = displayName ?? number
        let avatar = contact?.photoData.flatMap(NSImage.init(data:))
        return VStack(spacing: 8) {
            infoBlock(title: title, number: number, startedAt: startedAt, avatar: avatar)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)

            HStack(spacing: 30) {
                callAction(
                    title: "拒接",
                    symbol: "phone.down.fill",
                    color: .red,
                    action: onReject
                )
                callAction(
                    title: "接听",
                    symbol: "phone.fill",
                    color: .green,
                    action: onAnswer
                )
            }
        }
        // 宽度对齐原生来电卡片（320pt），内容居中；高度仍随内容自适应
        .frame(width: 292)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func infoBlock(
        title: String,
        number: String,
        startedAt: Date,
        avatar: NSImage?
    ) -> some View {
        VStack(spacing: 3) {
            // 仅当通讯录里有照片时显示头像；号码居中展示
            if let avatar {
                Image(nsImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            }
            Text("DJOneHub 来电")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
            if title != number {
                Text("\(number) · \(startedAt, style: .time) · 点击查看详情")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text("\(startedAt, style: .time) · 点击查看详情")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func callAction(
        title: String,
        symbol: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(color)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    private func smsView(sender: String, preview: String, code: String?) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: code == nil ? "message.fill" : "number.square.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.green.opacity(0.16))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(sender)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        Text("现在")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    private func missedView(number: String, startedAt: Date) -> some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "phone.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("未接来电")
                        .font(.system(size: 12, weight: .semibold))
                    Text(number)
                        .font(.caption)
                    Text(startedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
        }
        .buttonStyle(.plain)
    }

    private func messageView(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }
}
