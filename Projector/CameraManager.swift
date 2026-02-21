//
//  CameraManager.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//
//  Pipeline Architecture:
//  ──────────────────────
//  Menu Bar Preview:  AVCaptureSession → AVCaptureVideoPreviewLayer (zero-copy GPU path)
//  HDMI Projection:   AVCaptureSession → AVCaptureVideoPreviewLayer (zero-copy GPU path)
//
//  Both the menu bar preview and the HDMI projection window use
//  AVCaptureVideoPreviewLayer — Apple's own optimized rendering path.
//  No AVCaptureVideoDataOutput is attached — this keeps the capture pipeline
//  clean with a single consumer (the preview layer), avoiding extra frame
//  copies that can cause stuttering with virtual cameras like Boom Camera.
//
//  Watchdog:
//  A timer checks the capture session state every 2 seconds.
//  If the session stops unexpectedly, it restarts automatically.
//

import AVFoundation
import Combine
import CoreMedia
import QuartzCore

@MainActor
final class CameraManager: ObservableObject {

    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice? {
        didSet {
            guard selectedCamera?.uniqueID != oldValue?.uniqueID else { return }
            reconfigureSession()
        }
    }
    @Published var isRunning = false
    @Published var configuredFPS: Double = 0
    @Published var currentResolution: String = ""
    @Published var currentCodec: String = ""

    // Camera format/mode selection
    @Published var availableCameraModes: [CameraMode] = []
    @Published var currentCameraMode: CameraMode?

    // Target resolution from the output display — used to pick the best default format
    var targetDisplayWidth: Int = 1920
    var targetDisplayHeight: Int = 1080

    let captureSession = AVCaptureSession()

    // Projection controller — for triggering preview layer rebuild on session restart
    weak var projectionController: ProjectionWindowController?

    private var currentInput: AVCaptureDeviceInput?
    private var deviceObservers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []

    // Watchdog timer — detects frozen capture card
    private var watchdogTimer: Timer?
    private var isRestarting = false

    init() {
        refreshCameraList()
        observeDeviceChanges()
        observeSessionEvents()
    }

    deinit {
        watchdogTimer?.invalidate()
        for observer in deviceObservers + sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Camera Enumeration

    func refreshCameraList() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discoverySession.devices

        if selectedCamera == nil, let first = availableCameras.first {
            selectedCamera = first
        }
    }

    // MARK: - Session Management

    func startSession() {
        guard !captureSession.isRunning else { return }

        if currentInput == nil {
            reconfigureSession()
        }

        Task.detached { [captureSession] in
            captureSession.startRunning()
            await MainActor.run { [weak self] in
                self?.isRunning = true
                self?.startWatchdog()
            }
        }
    }

    func stopSession() {
        guard captureSession.isRunning else { return }
        stopWatchdog()

        Task.detached { [captureSession] in
            captureSession.stopRunning()
            await MainActor.run { [weak self] in
                self?.isRunning = false
                self?.configuredFPS = 0
            }
        }
    }

    /// Restart the capture session to recover from stalls.
    /// After restart, also rebuilds the projection preview layer.
    func restartSession() {
        guard !isRestarting else { return }
        isRestarting = true
        print("[Camera] Restarting session to recover from stall")

        Task.detached { [captureSession, weak self] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
            // Brief pause to let the capture card reset
            try? await Task.sleep(for: .milliseconds(300))
            captureSession.startRunning()

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRestarting = false
                self.isRunning = captureSession.isRunning
                if captureSession.isRunning {
                    print("[Camera] Session restarted successfully")
                    self.projectionController?.fullRebuildPreviewLayer()
                }
            }
        }
    }

    // MARK: - Configuration

    private func reconfigureSession() {
        guard let device = selectedCamera else { return }

        // Disable macOS system video effects BEFORE session configuration.
        disableSystemVideoEffects(for: device)

        captureSession.beginConfiguration()

        // Remove existing input
        if let existing = currentInput {
            captureSession.removeInput(existing)
            currentInput = nil
        }

        // Add new input — NO output attached.
        // The ONLY consumer is AVCaptureVideoPreviewLayer.
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                currentInput = input
            }
        } catch {
            print("Failed to create camera input: \(error.localizedDescription)")
            captureSession.commitConfiguration()
            return
        }

        // Configure best format
        configureBestFormat(for: device)

        captureSession.commitConfiguration()

        // Log device info
        let isExternal = device.deviceType == .external
        print("[Camera] Device: \(device.localizedName) (external: \(isExternal))")
    }

    /// Disable macOS system video effects that intercept the CMIO pipeline.
    private func disableSystemVideoEffects(for device: AVCaptureDevice) {
        if AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
            print("[Camera] Disabled Center Stage")
        }

        if device.isPortraitEffectActive {
            print("[Camera] Warning: Portrait Effect is active — prefer non-portrait format")
            print("[Camera] To avoid frame drops, disable Portrait Effect in System Settings > Camera")
        }
    }

    private func configureBestFormat(for device: AVCaptureDevice) {
        var modes: [CameraMode] = []

        for format in device.formats {
            let desc = format.formatDescription
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            let subType = CMFormatDescriptionGetMediaSubType(desc)

            let bestRange = format.videoSupportedFrameRateRanges
                .max(by: { $0.maxFrameRate < $1.maxFrameRate })

            guard let range = bestRange, range.maxFrameRate >= 15 else { continue }

            let width = Int(dimensions.width)
            let height = Int(dimensions.height)
            let maxFPS = range.maxFrameRate
            let fourCC = fourCharCodeToString(subType)

            let hasPortrait = format.isPortraitEffectSupported
            let hasCenterStage = format.isCenterStageSupported

            modes.append(CameraMode(
                format: format,
                width: width,
                height: height,
                maxFPS: maxFPS,
                codec: fourCC,
                hasPortraitEffect: hasPortrait,
                hasCenterStage: hasCenterStage
            ))
        }

        // Sort: prefer formats WITHOUT system video effects,
        // then standard aspect ratios (16:9, 4:3) over square/unusual,
        // then highest resolution, then highest FPS, then raw formats.
        modes.sort { a, b in
            let aClean = !a.hasPortraitEffect && !a.hasCenterStage
            let bClean = !b.hasPortraitEffect && !b.hasCenterStage
            if aClean != bClean { return aClean }

            let aStandard = isStandardAspectRatio(width: a.width, height: a.height)
            let bStandard = isStandardAspectRatio(width: b.width, height: b.height)
            if aStandard != bStandard { return aStandard }

            let pixelsA = a.width * a.height
            let pixelsB = b.width * b.height
            if pixelsA != pixelsB { return pixelsA > pixelsB }
            if a.maxFPS != b.maxFPS { return a.maxFPS > b.maxFPS }
            let aRaw = a.codec == "420v" || a.codec == "420f" || a.codec == "yuvs"
            let bRaw = b.codec == "420v" || b.codec == "420f" || b.codec == "yuvs"
            if aRaw != bRaw { return aRaw }
            return false
        }

        // Deduplicate
        var seen = Set<String>()
        modes = modes.filter { mode in
            let key = "\(mode.width)x\(mode.height)@\(Int(mode.maxFPS))_\(mode.codec)"
            return seen.insert(key).inserted
        }

        availableCameraModes = modes

        // Pick the best default: prefer matching output display resolution
        let targetW = targetDisplayWidth
        let targetH = targetDisplayHeight
        let best = modes.first(where: { $0.width == targetW && $0.height == targetH && $0.maxFPS >= 30 })
            ?? modes.first(where: { $0.width == targetW && $0.height == targetH })
            ?? modes.first(where: { $0.maxFPS >= 30 })
            ?? modes.first(where: { $0.maxFPS >= 24 })
            ?? modes.first
        if let best {
            applyCameraMode(best, to: device)
            if best.hasPortraitEffect || best.hasCenterStage {
                print("[Camera] Warning: selected format supports system effects (Portrait/CenterStage)")
                print("[Camera] This may cause frame drops. Disable effects in System Settings > Camera")
            }
        }
    }

    func applyCameraMode(_ mode: CameraMode) {
        guard let device = selectedCamera else { return }
        applyCameraMode(mode, to: device)
    }

    private func isStandardAspectRatio(width: Int, height: Int) -> Bool {
        guard height > 0 else { return false }
        let ratio = Double(width) / Double(height)
        return ratio > 1.2 && ratio < 2.5
    }

    private func applyCameraMode(_ mode: CameraMode, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.activeFormat = mode.format
            let targetFPS = min(mode.maxFPS, 60)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.unlockForConfiguration()

            configuredFPS = targetFPS
            currentResolution = "\(mode.width)x\(mode.height)"
            currentCodec = mode.codec
            currentCameraMode = mode
            print("[Camera] Format: \(mode.width)x\(mode.height) @ \(targetFPS)fps, codec: \(mode.codec)")
        } catch {
            print("Failed to configure format: \(error.localizedDescription)")
        }
    }

    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - Session Event Observation

    private func observeSessionEvents() {
        let interruptionObs = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: captureSession,
            queue: .main
        ) { [weak self] _ in
            print("[Camera] Session interrupted")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.restartSession()
            }
        }

        let interruptionEndedObs = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: captureSession,
            queue: .main
        ) { _ in
            print("[Camera] Session interruption ended")
        }

        let errorObs = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: captureSession,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            print("[Camera] Session runtime error: \(error?.localizedDescription ?? "unknown")")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.restartSession()
            }
        }

        sessionObservers = [interruptionObs, interruptionEndedObs, errorObs]
    }

    // MARK: - Watchdog Timer

    private func startWatchdog() {
        stopWatchdog()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.isRestarting else { return }

                if !self.captureSession.isRunning {
                    print("[Camera] Watchdog: session stopped unexpectedly, restarting")
                    self.restartSession()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Device Observation

    private func observeDeviceChanges() {
        let connectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCameraList()
            }
        }

        let disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let device = notif.object as? AVCaptureDevice
            let disconnectedID = device?.uniqueID
            MainActor.assumeIsolated {
                guard let self else { return }
                if let disconnectedID, disconnectedID == self.selectedCamera?.uniqueID {
                    self.selectedCamera = self.availableCameras.first
                }
                self.refreshCameraList()
            }
        }

        deviceObservers = [connectObserver, disconnectObserver]
    }
}

// MARK: - Camera Mode Model

struct CameraMode: Identifiable, Hashable {
    let format: AVCaptureDevice.Format
    let width: Int
    let height: Int
    let maxFPS: Double
    let codec: String
    let hasPortraitEffect: Bool
    let hasCenterStage: Bool

    var id: ObjectIdentifier { ObjectIdentifier(format) }

    var label: String {
        var text = "\(width)x\(height) @ \(Int(maxFPS)) fps (\(codec))"
        if hasPortraitEffect || hasCenterStage {
            text += " ⚠️"
        }
        return text
    }

    static func == (lhs: CameraMode, rhs: CameraMode) -> Bool {
        lhs.format === rhs.format
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
