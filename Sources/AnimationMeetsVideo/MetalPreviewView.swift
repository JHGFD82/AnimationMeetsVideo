import MetalKit
import SwiftUI

struct MetalPreviewView: NSViewRepresentable {
    func makeCoordinator() -> MetalPreviewRenderer {
        MetalPreviewRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.055, green: 0.07, blue: 0.1, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.setNeedsDisplay()
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.setNeedsDisplay()
    }
}

final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    override init() {
        device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue?.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            return
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
