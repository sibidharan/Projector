//
//  ProjectorApp.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//

import SwiftUI

@main
struct ProjectorApp: App {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var audioManager = AudioManager()
    private let projectionController = ProjectionWindowController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                cameraManager: cameraManager,
                displayManager: displayManager,
                audioManager: audioManager,
                projectionController: projectionController
            )
            .onAppear {
                // Wire up the projection controller reference so the watchdog
                // can trigger preview layer reconnection on session restart
                cameraManager.projectionController = projectionController
            }
        } label: {
            Image(systemName: "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }
}
