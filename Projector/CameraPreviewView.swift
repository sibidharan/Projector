//
//  CameraPreviewView.swift
//  Projector
//
//  Created by Sibidharan on 20/02/26.
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: NSViewRepresentable {

    let captureSession: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resizeAspect
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = previewLayer

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let previewLayer = nsView.layer as? AVCaptureVideoPreviewLayer else { return }
        if previewLayer.session !== captureSession {
            previewLayer.session = captureSession
        }
    }
}
