import Foundation

/// A deliberately isolated observer for the MaVo media route. It never runs
/// in a UAC IOProc or playback callback: the media loop merely hands it PCM
/// copies and this serial queue performs all file I/O.
final class MaVoCallRecorder {
    private let queue = DispatchQueue(label: "app.djonehub.mavo.recording", qos: .utility)
    private let lock = NSLock()
    private var file: FileHandle?
    private var url: URL?
    private var byteCount: UInt64 = 0
    private var pendingBlocks = 0
    private let maximumPendingBlocks = 64

    var isRecording: Bool { lock.withLock { file != nil } }

    func start() throws -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DJOneHub/recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let target = directory.appendingPathComponent("通话录音_\(formatter.string(from: Date())).wav")
        FileManager.default.createFile(atPath: target.path, contents: wavHeader(dataBytes: 0))
        let handle = try FileHandle(forWritingTo: target)
        lock.withLock {
            file?.closeFile()
            file = handle
            url = target
            byteCount = 0
            pendingBlocks = 0
        }
        return target.path
    }

    func enqueue(far: Data, near: Data) {
        guard isRecording else { return }
        lock.lock()
        guard file != nil, pendingBlocks < maximumPendingBlocks else { lock.unlock(); return }
        pendingBlocks += 1
        lock.unlock()
        queue.async { [weak self] in
            defer { self?.lock.withLock { self?.pendingBlocks = max(0, (self?.pendingBlocks ?? 1) - 1) } }
            guard let self else { return }
            // The module downlink is the clock source. Never write an extra
            // record for uplink-only data: that stretches the WAV timeline
            // and was the source of the apparent dropped/catching-up audio.
            let frames = far.count / 2
            guard frames > 0 else { return }
            var interleaved = Data(capacity: frames * 4)
            for index in 0 ..< frames {
                let offset = index * 2
                interleaved.append(offset + 1 < far.count ? far[offset] : 0)
                interleaved.append(offset + 1 < far.count ? far[offset + 1] : 0)
                interleaved.append(offset + 1 < near.count ? near[offset] : 0)
                interleaved.append(offset + 1 < near.count ? near[offset + 1] : 0)
            }
            self.lock.withLock {
                guard let file = self.file else { return }
                file.write(interleaved)
                self.byteCount += UInt64(interleaved.count)
            }
        }
    }

    func stop(completion: @escaping (String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { completion(nil); return }
            let result: String? = self.lock.withLock {
                guard let file = self.file, let url = self.url else { return nil }
                file.synchronizeFile()
                try? file.seek(toOffset: 0)
                try? file.write(contentsOf: self.wavHeader(dataBytes: self.byteCount))
                file.closeFile()
                self.file = nil
                self.url = nil
                self.byteCount = 0
                return url.path
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func wavHeader(dataBytes: UInt64) -> Data {
        var data = Data()
        func text(_ value: String) { data.append(value.data(using: .ascii)!) }
        func u16(_ value: UInt16) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 2)) }
        func u32(_ value: UInt32) { var v = value.littleEndian; data.append(Data(bytes: &v, count: 4)) }
        text("RIFF"); u32(UInt32(min(dataBytes + 36, UInt64(UInt32.max)))); text("WAVEfmt ")
        u32(16); u16(1); u16(2); u32(8_000); u32(32_000); u16(4); u16(16)
        text("data"); u32(UInt32(min(dataBytes, UInt64(UInt32.max))))
        return data
    }
}
