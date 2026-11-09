import SwiftUI
import Combine

/// How strong retro mode looks, in the guide and in full screen alike. Picked on a living
/// room TV on 2026-10-18 from three trial looks: the old one (scanlines 0.12, and none in
/// full screen, which read as too subtle), this one, and a stronger one. The Roku port
/// matches these numbers.
enum RetroLook {
    static let scanlineOpacity = 0.18
    static let cornerShadow = 0.78
    static let topBottomShadow = 0.58
    static let sideShadow = 0.48
    /// Chance per 80 ms tick that the scanlines dip, and how far.
    static let flickerChance = 0.08
    static let flickerRange = 0.76...0.88
}

/// CRT effect overlay: scanlines, vignette, flicker. (A white VHS tracking line used to run
/// down the screen now and then; it drew the eye and was taken out.)
struct CRTOverlayView: View {
    @State private var flickerOpacity: Double = 1.0
    let flickerTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Scanlines
            ScanlineLayer(opacity: RetroLook.scanlineOpacity)
                .opacity(flickerOpacity)

            // Vignette (dark edges, simulates tube curvature)
            VignetteLayer()

            // Screen edge glow
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.04), lineWidth: 2)
        }
        .allowsHitTesting(false)
        .onReceive(flickerTimer) { _ in
            let roll = Double.random(in: 0...1)
            if roll > 1 - RetroLook.flickerChance {
                withAnimation(.easeInOut(duration: 0.03)) {
                    flickerOpacity = Double.random(in: RetroLook.flickerRange)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    withAnimation(.easeInOut(duration: 0.03)) {
                        flickerOpacity = 1.0
                    }
                }
            }
        }
    }
}

// MARK: - Scanline layer

private struct ScanlineLayer: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            // Horizontal scanlines every 3px
            let spacing: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.black.opacity(opacity)), lineWidth: 1.5)
                y += spacing
            }
        }
    }
}

// MARK: - Vignette layer

private struct VignetteLayer: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack {
                // Corner shadows (heavier than edges)
                RadialGradient(
                    gradient: Gradient(colors: [.clear, .clear, .black.opacity(RetroLook.cornerShadow)]),
                    center: .center,
                    startRadius: min(w, h) * 0.3,
                    endRadius: max(w, h) * 0.7
                )

                // Top/bottom edge darkening
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(RetroLook.topBottomShadow), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: h * 0.08)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, .black.opacity(RetroLook.topBottomShadow)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: h * 0.08)
                }

                // Left/right edge darkening
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(RetroLook.sideShadow), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.06)

                    Spacer()

                    LinearGradient(
                        colors: [.clear, .black.opacity(RetroLook.sideShadow)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: w * 0.06)
                }
            }
        }
    }
}
