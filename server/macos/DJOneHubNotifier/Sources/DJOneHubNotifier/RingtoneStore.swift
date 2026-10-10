import Foundation
import AppKit
import UniformTypeIdentifiers

/// 铃声数据模型：系统音效（内置）或自定义音频文件。
struct Ringtone: Identifiable, Equatable {
    let id: String
    let name: String
    let systemName: String?
    let url: URL?
}

/// 铃声数据中心：内置系统音效 + 自定义铃声目录，负责来电循环播放与试听。
@MainActor
final class RingtoneStore: ObservableObject {
    @Published var selectedID: String
    @Published var customRingtones: [Ringtone] = []

    private let defaultsKey = "selectedRingtoneID"
    private var ringingSound: NSSound?
    private var previewSound: NSSound?

    static let builtins: [Ringtone] = [
        Ringtone(id: "system-glass", name: "Glass（默认）", systemName: "Glass", url: nil),
        Ringtone(id: "system-hero", name: "Hero", systemName: "Hero", url: nil),
        Ringtone(id: "system-ping", name: "Ping", systemName: "Ping", url: nil),
        Ringtone(id: "system-pop", name: "Pop", systemName: "Pop", url: nil),
        Ringtone(id: "system-sosumi", name: "Sosumi", systemName: "Sosumi", url: nil),
        Ringtone(id: "system-tink", name: "Tink", systemName: "Tink", url: nil),
        Ringtone(id: "system-funk", name: "Funk", systemName: "Funk", url: nil),
        Ringtone(id: "system-basso", name: "Basso", systemName: "Basso", url: nil),
    ]

    static var ringtoneDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("DJOneHub/ringtones", isDirectory: true)
    }

    init() {
        selectedID = UserDefaults.standard.string(forKey: defaultsKey) ?? Self.builtins[0].id
        scanCustom()
    }

    var all: [Ringtone] { Self.builtins + customRingtones }

    var selected: Ringtone? { all.first { $0.id == selectedID } }

    func select(_ ringtone: Ringtone) {
        selectedID = ringtone.id
        UserDefaults.standard.set(ringtone.id, forKey: defaultsKey)
    }

    func scanCustom() {
        let fm = FileManager.default
        let dir = Self.ringtoneDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let supported = ["aiff", "aif", "wav", "mp3", "m4a", "caf"]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        customRingtones = files
            .filter { supported.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map {
                Ringtone(
                    id: "custom-\($0.lastPathComponent)",
                    name: $0.deletingPathExtension().lastPathComponent,
                    systemName: nil,
                    url: $0
                )
            }
        if selectedID.hasPrefix("custom-"),
           !customRingtones.contains(where: { $0.id == selectedID }) {
            selectedID = Self.builtins[0].id
            UserDefaults.standard.set(selectedID, forKey: defaultsKey)
        }
    }

    func startRinging() {
        stopRinging()
        guard let ringtone = selected else { return }
        let sound = makeSound(ringtone)
        sound?.loops = true
        sound?.volume = 0.9
        sound?.play()
        ringingSound = sound
    }

    func stopRinging() {
        ringingSound?.stop()
        ringingSound = nil
    }

    func preview(_ ringtone: Ringtone) {
        previewSound?.stop()
        let sound = makeSound(ringtone)
        sound?.loops = false
        sound?.volume = 1.0
        sound?.play()
        previewSound = sound
    }

    private func makeSound(_ ringtone: Ringtone) -> NSSound? {
        if let url = ringtone.url {
            return NSSound(contentsOf: url, byReference: true)
        }
        if let name = ringtone.systemName {
            return NSSound(named: name)
        }
        return nil
    }

    func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.title = "选择铃声文件"
        panel.allowedContentTypes = [.aiff, .wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = Self.ringtoneDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.copyItem(at: url, to: dest)
        scanCustom()
    }

    func revealFolder() {
        let dir = Self.ringtoneDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}
