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

            // Controls
            VStack(spacing: 10) {
                cameraSection
                cameraModeSection
                displaySection
                displayModeSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Audio
            audioSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()

            // Rendering
            renderingSection
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
        .frame(width: 320)
        .onAppear {
            cameraManager.startSession()
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(spacing: 8) {
            CameraPreviewView(captureSession: cameraManager.captureSession)
                .frame(height: 174)
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
                    Image(systemName: "mic.fill")
                        .font(.system(size: 8))
                    levelIndicator
                }
                .foregroundStyle(.green)
            }

            Spacer()
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private var levelIndicator: some View {
        AudioLevelIndicator(audioManager: audioManager)
    }

    // MARK: - Camera Selection

    private var cameraSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .frame(width: 16)
                .foregroundStyle(.secondary)
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
    }

    // MARK: - Camera Mode Selection

    private var cameraModeSection: some View {
        Group {
            if !cameraManager.availableCameraModes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.dashed")
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
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
        }
    }

    // MARK: - Display Selection

    private var displaySection: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "display")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                if displayManager.availableDisplays.isEmpty {
                    Text("No external displays")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                    Spacer()
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
        }
    }

    // MARK: - Display Mode Picker

    private var displayModeSection: some View {
        Group {
            if !displayManager.availableModes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "aspectratio")
                        .frame(width: 16)
                        .foregroundStyle(.secondary)
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
        }
    }

    // MARK: - Audio Section

    private var audioSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Picker("Microphone", selection: $audioManager.selectedMic) {
                    Text("No audio").tag(nil as AVCaptureDevice?)
                    ForEach(audioManager.availableMics, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device as AVCaptureDevice?)
                    }
                }
                .labelsHidden()
            }

            if let error = audioManager.routingError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(error)
                        .font(.caption2)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 24)
            }
        }
    }

    // MARK: - Rendering Section

    private var renderingSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "memorychip.fill")
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text("Native Preview Layer")
                .font(.callout)
            Spacer()
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
            Text("Projector")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
        }
    }

    // MARK: - Live Stats (isolated to prevent full-body redraw)

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
