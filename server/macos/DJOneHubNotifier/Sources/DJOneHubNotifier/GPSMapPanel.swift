import AppKit
import MapKit

@MainActor
final class GPSMapPanel: NSObject {
    private let panel: NSPanel
    private let mapView = MKMapView()
    private let mapOverlay = NSVisualEffectView()
    private let stateLabel = NSTextField(labelWithString: "正在搜索卫星")
    private let detailLabel = NSTextField(labelWithString: "GPS 校准完成后显示当前位置")
    private let satelliteValue = NSTextField(labelWithString: "正在查找")
    private let accuracyValue = NSTextField(labelWithString: "等待定位")
    private let signalLabel = NSTextField(labelWithString: "GPS 信号")
    private let signalBars = NSStackView()
    private var marker: MKPointAnnotation?
    private var barViews: [NSView] = []

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 164),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        buildContent()
    }

    func show() {
        positionAtTopRight()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func update(with fix: GPSFixSummary?) {
        guard let fix,
              let latitude = Self.coordinate(fix.latitude, valid: -90...90),
              let longitude = Self.coordinate(fix.longitude, valid: -180...180)
        else {
            showSearchingState()
            return
        }

        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let annotation = marker ?? MKPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = "DJOneHub GPS"
        if marker == nil {
            marker = annotation
            mapView.addAnnotation(annotation)
        }
        mapOverlay.isHidden = true
        mapView.alphaValue = 1
        stateLabel.stringValue = "当前位置已锁定"
        detailLabel.stringValue = "模块定位已连接"
        satelliteValue.stringValue = "\(fix.satellites) 颗卫星"
        accuracyValue.stringValue = "HDOP \(fix.hdop)"
        setSignalBars(active: signalStrength(for: fix))
        mapView.setRegion(
            MKCoordinateRegion(center: coordinate, latitudinalMeters: 500, longitudinalMeters: 500),
            animated: true
        )
    }

    private func buildContent() {
        let root = NSVisualEffectView()
        root.material = .underWindowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 22
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.75).cgColor
        panel.contentView = root

        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = 16
        mapView.layer?.masksToBounds = true
        showChinaOverview()

        mapOverlay.material = .popover
        mapOverlay.blendingMode = .withinWindow
        mapOverlay.state = .active
        mapOverlay.wantsLayer = true
        mapOverlay.layer?.cornerRadius = 16
        mapOverlay.translatesAutoresizingMaskIntoConstraints = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let overlayLabel = NSTextField(labelWithString: "中国 · 校准中")
        overlayLabel.font = .systemFont(ofSize: 11, weight: .medium)
        let overlayStack = NSStackView(views: [spinner, overlayLabel])
        overlayStack.orientation = .vertical
        overlayStack.alignment = .centerX
        overlayStack.spacing = 5
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        mapOverlay.addSubview(overlayStack)

        stateLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        satelliteValue.font = .systemFont(ofSize: 11, weight: .medium)
        satelliteValue.textColor = .secondaryLabelColor
        accuracyValue.font = .systemFont(ofSize: 11, weight: .medium)
        accuracyValue.textColor = .secondaryLabelColor
        signalLabel.font = .systemFont(ofSize: 11, weight: .medium)
        signalLabel.textColor = .secondaryLabelColor

        signalBars.orientation = .horizontal
        signalBars.alignment = .bottom
        signalBars.spacing = 3
        for height in [5, 8, 11, 14] {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 2
            bar.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            signalBars.addArrangedSubview(bar)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 4),
                bar.heightAnchor.constraint(equalToConstant: CGFloat(height)),
            ])
            barViews.append(bar)
        }

        let signalRow = NSStackView(views: [signalLabel, signalBars])
        signalRow.orientation = .horizontal
        signalRow.alignment = .centerY
        signalRow.spacing = 7
        let metricsRow = NSStackView(views: [satelliteValue, accuracyValue])
        metricsRow.orientation = .horizontal
        metricsRow.alignment = .centerY
        metricsRow.spacing = 10
        let textStack = NSStackView(views: [stateLabel, detailLabel, metricsRow, signalRow])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5
        textStack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(mapView)
        root.addSubview(mapOverlay)
        root.addSubview(textStack)
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            mapView.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            mapView.widthAnchor.constraint(equalToConstant: 138),
            mapView.heightAnchor.constraint(equalToConstant: 132),
            mapOverlay.leadingAnchor.constraint(equalTo: mapView.leadingAnchor),
            mapOverlay.trailingAnchor.constraint(equalTo: mapView.trailingAnchor),
            mapOverlay.topAnchor.constraint(equalTo: mapView.topAnchor),
            mapOverlay.bottomAnchor.constraint(equalTo: mapView.bottomAnchor),
            overlayStack.centerXAnchor.constraint(equalTo: mapOverlay.centerXAnchor),
            overlayStack.centerYAnchor.constraint(equalTo: mapOverlay.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: mapView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -15),
            textStack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        setSignalBars(active: 1)
    }

    private func positionAtTopRight() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 24, y: visible.maxY - panel.frame.height - 24))
    }

    private func showSearchingState() {
        if let marker {
            mapView.removeAnnotation(marker)
            self.marker = nil
        }
        mapOverlay.isHidden = false
        mapOverlay.alphaValue = 0.56
        mapView.alphaValue = 0.42
        showChinaOverview()
        stateLabel.stringValue = "正在搜索卫星"
        detailLabel.stringValue = "GPS 校准完成后显示当前位置"
        satelliteValue.stringValue = "正在查找"
        accuracyValue.stringValue = "等待定位"
        setSignalBars(active: 1)
    }

    private func setSignalBars(active: Int) {
        for (index, bar) in barViews.enumerated() {
            bar.layer?.backgroundColor = (index < active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).cgColor
        }
    }

    private func showChinaOverview() {
        mapView.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 35.8617, longitude: 104.1954),
                span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 45)
            ),
            animated: false
        )
    }

    private func signalStrength(for fix: GPSFixSummary) -> Int {
        guard let satellites = Int(fix.satellites), let hdop = Double(fix.hdop) else { return 1 }
        if satellites >= 10 && hdop <= 1.2 { return 4 }
        if satellites >= 8 && hdop <= 2 { return 3 }
        if satellites >= 6 && hdop <= 3.5 { return 2 }
        return 1
    }

    private static func coordinate(_ raw: String?, valid range: ClosedRange<Double>) -> CLLocationDegrees? {
        guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), range.contains(value) else {
            return nil
        }
        return value
    }
}
