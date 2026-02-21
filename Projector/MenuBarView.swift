//
//  MenuBarView.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//

import SwiftUI
import AVFoundation

struct MenuBarView: View {
    @ObservedObject var cameraManager: CameraManager
    @ObservedObject var displayManager: DisplayManager
    @ObservedObject var audioManager: AudioManager
    let projectionController: ProjectionWindowController

    var body: some View {
        VStack(spacing: 0) {
            // Preview
            previewSection
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            // INPUT section
            inputSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // OUTPUT section
            outputSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // Project button
            projectionButton
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .onAppear {
            // Set target resolution from selected display so camera picks matching format
            if let display = displayManager.selectedDisplay {
                cameraManager.targetDisplayWidth = display.resolutionWidth
                cameraManager.targetDisplayHeight = display.resolutionHeight
            }
            cameraManager.startSession()
            audioManager.updateCameraAudioDevice(for: cameraManager.selectedCamera)
            // Enable level metering only while the popover is visible
            audioManager._meterEnabled = true
        }
        .onDisappear {
            // Disable metering when popover closes — saves CPU on audio thread
            audioManager._meterEnabled = false
            audioManager.inputLevel = 0
        }
        .onChange(of: cameraManager.selectedCamera) { _, newCamera in
            audioManager.updateCameraAudioDevice(for: newCamera)
        }
        .onChange(of: displayManager.selectedDisplay) { _, newDisplay in
            if let display = newDisplay {
                cameraManager.targetDisplayWidth = display.resolutionWidth
                cameraManager.targetDisplayHeight = display.resolutionHeight
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(spacing: 8) {
            CameraPreviewView(captureSession: cameraManager.captureSession)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    statusPills
                        .padding(6)
                }

            liveStatsBar
        }
    }

    private var statusPills: some View {
        HStack(spacing: 4) {
            if displayManager.isProjecting {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
        }
    }

    private var liveStatsBar: some View {
        HStack(spacing: 6) {
            if !cameraManager.currentResolution.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 8))
                    Text(cameraManager.currentResolution)
                    Text("\(Int(cameraManager.configuredFPS))fps")
                }
            }

            if displayManager.isProjecting, let display = displayManager.selectedDisplay {
                Text("\u{2022}")
                    .foregroundStyle(.tertiary)
                HStack(spacing: 3) {
                    Image(systemName: "display")
                        .font(.system(size: 8))
                    Text(display.resolutionString)
                }
                .foregroundStyle(.green)
            }

            if audioManager.isRouting {
                Text("\u{2022}")
                    .foregroundStyle(.tertiary)
                HStack(spacing: 3) {
                    Image(systemName: audioManager.isCameraAudioSelected ? "video.fill" : "mic.fill")
                        .font(.system(size: 8))
                    AudioLevelIndicator(audioManager: audioManager)
                }
                .foregroundStyle(.green)
            }

            Spacer()
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    // MARK: - INPUT Section

    private var inputSection: some View {
        VStack(spacing: 0) {
            // Section header
            sectionHeader("INPUT", icon: "arrow.down.circle.fill", color: .blue)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                // Video source
                pickerRow(icon: "camera.fill", iconColor: .primary) {
                    Picker("Camera", selection: $cameraManager.selectedCamera) {
                        if cameraManager.availableCameras.isEmpty {
                            Text("No cameras").tag(nil as AVCaptureDevice?)
                        }
                        ForEach(cameraManager.availableCameras, id: \.uniqueID) { device in
                            Text(device.localizedName).tag(device as AVCaptureDevice?)
                        }
                    }
                    .labelsHidden()
                }

                // Video format
                if !cameraManager.availableCameraModes.isEmpty {
                    pickerRow(icon: "film", iconColor: .primary) {
                        Picker("Format", selection: Binding(
                            get: { cameraManager.currentCameraMode },
                            set: { newMode in
                                if let mode = newMode {
                                    cameraManager.applyCameraMode(mode)
                                }
                            }
                        )) {
                            ForEach(cameraManager.availableCameraModes) { mode in
                                Text(mode.label).tag(mode as CameraMode?)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // Audio source
                pickerRow(
                    icon: audioManager.isCameraAudioSelected ? "video.fill" : "mic.fill",
                    iconColor: .primary
                ) {
                    Picker("Audio", selection: Binding(
                        get: { AudioPickerOption.from(audioManager: audioManager) },
                        set: { newValue in
                            switch newValue {
                            case .none:
                                audioManager.selectMicrophone(nil)
                            case .cameraAudio:
                                audioManager.selectCameraAudio()
                            case .microphone(let uniqueID):
                                let device = audioManager.availableMics.first { $0.uniqueID == uniqueID }
                                audioManager.selectMicrophone(device)
                            }
                        }
                    )) {
                        Text("No audio").tag(AudioPickerOption.none)

                        if let camAudio = audioManager.cameraAudioDevice {
                            Text("\(Image(systemName: "video.fill")) Camera Audio (\(camAudio.localizedName))")
                                .tag(AudioPickerOption.cameraAudio)
                        }

                        ForEach(audioManager.availableMics, id: \.uniqueID) { device in
                            Text(device.localizedName)
                                .tag(AudioPickerOption.microphone(device.uniqueID))
                        }
                    }
                    .labelsHidden()
                }

                // Audio error
                if let error = audioManager.routingError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(error)
                            .font(.caption2)
                            .lineLimit(2)
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                }
            }
        }
    }

    // MARK: - OUTPUT Section

    private var outputSection: some View {
        VStack(spacing: 0) {
            // Section header
            sectionHeader("OUTPUT", icon: "arrow.up.circle.fill", color: .green)
                .padding(.bottom, 10)

            VStack(spacing: 8) {
                // Display picker
                pickerRow(icon: "display", iconColor: .primary) {
                    if displayManager.availableDisplays.isEmpty {
                        Text("No external displays")
                            .foregroundStyle(.tertiary)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Picker("Display", selection: $displayManager.selectedDisplay) {
                            ForEach(displayManager.availableDisplays) { display in
                                Text(display.name).tag(display as ExternalDisplay?)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: displayManager.selectedDisplay) {
                            displayManager.refreshModes()
                        }
                    }
                }

                // Display mode / resolution
                if !displayManager.availableModes.isEmpty {
                    pickerRow(icon: "aspectratio", iconColor: .primary) {
                        Picker("Mode", selection: Binding(
                            get: { displayManager.currentMode },
                            set: { newMode in
                                if let mode = newMode {
                                    displayManager.applyMode(mode)
                                }
                            }
                        )) {
                            ForEach(displayManager.availableModes) { mode in
                                Text(mode.label).tag(mode as DisplayMode?)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // Mirroring warning
                if let selected = displayManager.selectedDisplay, selected.isMirroring {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.caption2)
                        Text("Mirroring will be stopped when projection starts")
                            .font(.caption2)
                    }
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                }

                // HDMI audio status when projecting
                if displayManager.isProjecting && audioManager.isRouting {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                            .frame(width: 16)
                        Text("Audio routed to HDMI")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Shared Components

    /// Section header with icon and label
    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .default))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// Picker row with leading icon — content stretches to fill width
    private func pickerRow<Content: View>(
        icon: String,
        iconColor: Color = .secondary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 16)
                .foregroundStyle(iconColor == .primary ? .secondary : iconColor)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Projection Button

    private var projectionButton: some View {
        Button(action: toggleProjection) {
            HStack(spacing: 6) {
                Image(systemName: displayManager.isProjecting ? "stop.fill" : "play.fill")
                Text(displayManager.isProjecting ? "Stop Projection" : "Start Projection")
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.glassProminent)
        .tint(displayManager.isProjecting ? .red : nil)
        .disabled(displayManager.selectedDisplay == nil)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("About") {
                AboutWindowController.shared.show()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    // MARK: - Audio Picker Option

    /// Represents audio source options in the picker.
    private enum AudioPickerOption: Hashable {
        case none
        case cameraAudio
        case microphone(String) // uniqueID

        static func from(audioManager: AudioManager) -> AudioPickerOption {
            if audioManager.selectedMic == nil {
                return .none
            } else if audioManager.isCameraAudioSelected {
                return .cameraAudio
            } else if let mic = audioManager.selectedMic {
                return .microphone(mic.uniqueID)
            }
            return .none
        }
    }

    // MARK: - Audio Level Indicator (isolated to prevent full-body redraw)

    /// Isolated view that only redraws when inputLevel changes.
    /// Prevents the entire MenuBarView body from re-evaluating on level updates.
    private struct AudioLevelIndicator: View {
        @ObservedObject var audioManager: AudioManager

        var body: some View {
            HStack(spacing: 1) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(index: i))
                        .frame(width: 2.5, height: 7)
                }
            }
        }

        private func barColor(index: Int) -> Color {
            let threshold = Float(index) / 8.0
            let level = min(audioManager.inputLevel * 5, 1.0)
            if level > threshold {
                if index >= 6 { return .red }
                if index >= 4 { return .orange }
                return .green
            }
            return .gray.opacity(0.3)
        }
    }

    // MARK: - Actions

    private func toggleProjection() {
        if displayManager.isProjecting {
            projectionController.stopProjection(cameraManager: cameraManager)
            displayManager.isProjecting = false
            audioManager.stopRouting()
            displayManager.refreshDisplayList()
        } else if let display = displayManager.selectedDisplay {
            projectionController.startProjection(
                displayID: display.displayID,
                cameraManager: cameraManager
            )
            displayManager.isProjecting = true
            displayManager.refreshDisplayList()

            // Auto-start audio routing
            if audioManager.selectedMic != nil {
                if let hdmiAudioID = AudioManager.hdmiAudioDeviceID(for: display.displayID) {
                    audioManager.startRouting(toOutputDeviceID: hdmiAudioID)
                }
            }
        }
    }
}
