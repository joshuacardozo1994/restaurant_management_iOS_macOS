//
//  Skeleton.swift
//  Durigo
//
//  Skeleton loaders: while a screen's data loads it draws its real layout
//  with sample data (see SampleData.swift), redacted to placeholder bars,
//  with a highlight sweeping left to right. A spinner on a button stays a
//  spinner; this is only for a screen or a section that has nothing yet.
//
//      TakingsPanel(d: .sample).skeleton(true)
//

import SwiftUI

extension View {
    /// The view as a loading placeholder: redacted, shimmering, not tappable,
    /// and read by VoiceOver as one "Loading" element. No-op when `active` is false.
    func skeleton(_ active: Bool) -> some View {
        modifier(SkeletonModifier(active: active))
    }
}

private struct SkeletonModifier: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active {
            content
                .redacted(reason: .placeholder)
                .mask { if reduceMotion { Rectangle() } else { ShimmerMask() } }
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading")
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            content
        }
    }
}

/// A band of full opacity sliding across a dimmer field, every 1.4s. Driven
/// by the clock (TimelineView) rather than a repeating animation, so it
/// can't leak into the layout's own animations.
private struct ShimmerMask: View {
    static let period: Double = 1.4
    /// Opacity away from the band
    static let floor: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: Self.period) / Self.period
                let w = max(geo.size.width, 1)
                // The band is 60% of the width and travels from fully off the
                // left edge to fully off the right edge
                let band = w * 0.6
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black, location: 0.5),
                        .init(color: .black.opacity(0), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: band)
                .offset(x: -band + (w + band) * phase)
                .frame(width: w, height: geo.size.height, alignment: .leading)
                .background(Color.black.opacity(Self.floor))
            }
        }
    }
}

// MARK: - Screenshotting the skeletons (DEBUG)

enum SkeletonPreview {
    /// `--skeleton-preview`: every screen's data stays loading, so its
    /// skeleton can be looked at. Sign-in still works.
    static let isActive: Bool = {
        #if DEBUG
        CommandLine.arguments.contains("--skeleton-preview")
        #else
        false
        #endif
    }()

    /// Waits until the task is cancelled (then throws CancellationError).
    /// Called before a data request when `isActive`.
    static func hang() async throws {
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
