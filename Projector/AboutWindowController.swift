//
//  AboutWindowController.swift
//  Projector
//
//  Created by Sibidharan on 21/02/26.
//

import SwiftUI
import AppKit

/// Manages a standalone About window for the app.
@MainActor
final class AboutWindowController {

    static let shared = AboutWindowController()

    private var window: NSWindow?

    func show() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let aboutView = AboutView()
        let hostingView = NSHostingView(rootView: aboutView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 340)

        let aboutWindow = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        aboutWindow.title = "About Projector"
        aboutWindow.contentView = hostingView
        aboutWindow.isReleasedWhenClosed = false
        aboutWindow.center()
        aboutWindow.isMovableByWindowBackground = true

        self.window = aboutWindow
        aboutWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - About View

private struct AboutView: View {

    private let version: String = {
        let marketing = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(marketing) (\(build))"
    }()

    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 4)

            // App icon placeholder
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.primary)

            // App name
            Text("Projector")
                .font(.system(size: 22, weight: .bold))

            // Version
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Description
            Text("Camera + Audio to HDMI")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .padding(.horizontal, 32)

            // Built by
            VStack(spacing: 4) {
                Text("Built by")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Link("Sibidharan", destination: URL(string: "https://instagram.com/sibidharan")!)
                    .font(.caption)
            }

            // License
            Text("MIT License")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Spacer().frame(height: 4)
        }
        .frame(width: 300, height: 340)
    }
}
