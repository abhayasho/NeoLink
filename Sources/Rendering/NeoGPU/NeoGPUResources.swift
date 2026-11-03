import Foundation
@preconcurrency import Metal

/// Pipelines compile off the UI thread once per device, shared by all surfaces.
final class NeoGPUResources: @unchecked Sendable {
    static let shared = NeoGPUResources()
    private let lock = NSLock()
    private var renderers: [UInt64: NeoGPURenderer] = [:]
    func prepare(device: MTLDevice) {
        lock.lock(); defer { lock.unlock() }
        if renderers[device.registryID] == nil { renderers[device.registryID] = try? NeoGPURenderer(device: device) }
    }
    func renderer(device: MTLDevice) -> NeoGPURenderer? {
        lock.lock(); defer { lock.unlock() }; return renderers[device.registryID]
    }
}
