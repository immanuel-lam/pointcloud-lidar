//
//  RendererTypes.swift
//  pointcloud
//
//  Created by Immanuel Lam on 26/3/2026.
//

import simd

struct PointVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

struct Uniforms {
    var projectionMatrix: float4x4
    var viewMatrix: float4x4
    var pointSize: Float
    var padding: SIMD3<Float> = .zero  // align to 16 bytes
}
