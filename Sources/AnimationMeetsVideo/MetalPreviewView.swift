import MetalKit
import QuartzCore
import SwiftUI

struct MetalPreviewView: NSViewRepresentable {
    func makeCoordinator() -> MetalPreviewRenderer {
        MetalPreviewRenderer()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.delegate = context.coordinator
        // rgba16Float + wantsExtendedDynamicRangeContent is the EDR-capable
        // configuration this preview pipeline will need once later
        // milestones (compositing, vector engine) actually render HDR
        // content through it, rather than just this placeholder clear color.
        view.colorPixelFormat = .rgba16Float
        view.clearColor = MTLClearColor(red: 0.055, green: 0.07, blue: 0.1, alpha: 1)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.wantsExtendedDynamicRangeContent = true
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        }
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        nsView.needsDisplay = true
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
