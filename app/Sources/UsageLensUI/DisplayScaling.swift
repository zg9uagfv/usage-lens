import AppKit
import SwiftUI

/// Immutable display-aware scaling metrics derived from a screen's logical size.
///
/// Core math operates on plain `CGSize` values with zero `NSScreen` side effects so
/// unit tests and offscreen `ImageRenderer` checks are 100% deterministic.
public struct DisplayScaleMetrics: Equatable, Sendable {
    public static let referenceDisplaySize = CGSize(width: 1440, height: 900)

    public static let minSizeScale: CGFloat = 0.85
    public static let maxSizeScale: CGFloat = 1.35

    public static let minFontScale: CGFloat = 0.88
    public static let maxFontScale: CGFloat = 1.30
    public static let minimumFontSize: CGFloat = 8.5

    public static let maxVisibleWidthRatio: CGFloat = 0.90
    public static let maxVisibleHeightRatio: CGFloat = 0.85

    // Base (1.0x) surface sizes
    public static let basePopoverSize = CGSize(width: 340, height: 560)
    public static let baseDevelopmentPanelSize = CGSize(width: 368, height: 620)
    public static let baseSettingsWindowSize = CGSize(width: 360, height: 520)
    public static let baseSettingsContentSize = CGSize(width: 340, height: 480)
    public static let baseAboutWindowSize = CGSize(width: 280, height: 230)

    public static let standard = DisplayScaleMetrics(sizeScale: 1.0, fontScale: 1.0, visibleSize: nil)

    public let sizeScale: CGFloat
    public let fontScale: CGFloat
    public let visibleSize: CGSize?

    public init(sizeScale: CGFloat, fontScale: CGFloat, visibleSize: CGSize? = nil) {
        self.sizeScale = sizeScale
        self.fontScale = fontScale
        self.visibleSize = visibleSize
    }

    /// Computes scaling metrics from logical display dimensions and optional usable visible area.
    /// Falls back to `.standard` if `displaySize` is zero, negative, or non-finite.
    public static func make(displaySize: CGSize, visibleSize: CGSize? = nil) -> DisplayScaleMetrics {
        guard displaySize.width.isFinite,
              displaySize.height.isFinite,
              displaySize.width > 0,
              displaySize.height > 0 else {
            return .standard
        }

        let sanitizedVisibleSize: CGSize?
        if let visibleSize,
           visibleSize.width.isFinite,
           visibleSize.height.isFinite,
           visibleSize.width > 0,
           visibleSize.height > 0 {
            sanitizedVisibleSize = visibleSize
        } else {
            sanitizedVisibleSize = nil
        }

        let widthRatio = displaySize.width / Self.referenceDisplaySize.width
        let heightRatio = displaySize.height / Self.referenceDisplaySize.height
        let rawRatio = min(widthRatio, heightRatio)
        let damped = sqrt(rawRatio)

        let sizeScale = quantize(min(max(damped, Self.minSizeScale), Self.maxSizeScale))
        let fontScale = quantize(min(max(damped, Self.minFontScale), Self.maxFontScale))

        return DisplayScaleMetrics(
            sizeScale: sizeScale,
            fontScale: fontScale,
            visibleSize: sanitizedVisibleSize
        )
    }

    /// Thin AppKit adapter reading `screen.frame.size` and `screen.visibleFrame.size`.
    public static func from(screen: NSScreen?) -> DisplayScaleMetrics {
        guard let screen else { return .standard }
        return make(displaySize: screen.frame.size, visibleSize: screen.visibleFrame.size)
    }

    /// Scales container dimensions (widths, heights, icon frames) to integer points.
    public func scaledDimension(_ base: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(minimum, (base * sizeScale).rounded())
    }

    /// Scales paddings, spacing, corner radii, and bar heights to half-point precision.
    public func scaledSpacing(_ base: CGFloat, minimum: CGFloat = 0) -> CGFloat {
        max(minimum, ((base * sizeScale) * 2).rounded() / 2)
    }

    /// Scales font sizes to half-point precision while enforcing a readability floor.
    public func scaledFontSize(_ base: CGFloat, minimum: CGFloat = DisplayScaleMetrics.minimumFontSize) -> CGFloat {
        max(minimum, ((base * fontScale) * 2).rounded() / 2)
    }

    /// Convenience helper producing a scaled system font.
    public func font(_ baseSize: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: scaledFontSize(baseSize), weight: weight)
    }

    /// Scales a base surface size and clamps it to the usable screen area when `visibleSize` is known.
    public func clampedSize(base: CGSize) -> CGSize {
        let scaledW = scaledDimension(base.width)
        let scaledH = scaledDimension(base.height)

        guard let visibleSize,
              visibleSize.width.isFinite,
              visibleSize.height.isFinite,
              visibleSize.width > 0,
              visibleSize.height > 0 else {
            return CGSize(width: scaledW, height: scaledH)
        }

        let maxW = floor(visibleSize.width * Self.maxVisibleWidthRatio)
        let maxH = floor(visibleSize.height * Self.maxVisibleHeightRatio)
        return CGSize(width: min(scaledW, maxW), height: min(scaledH, maxH))
    }

    public var panelWidth: CGFloat {
        let scaled = scaledDimension(Theme.panelWidth)
        guard let visibleSize,
              visibleSize.width.isFinite,
              visibleSize.width > 0 else {
            return scaled
        }
        return min(scaled, floor(visibleSize.width * Self.maxVisibleWidthRatio))
    }

    public var popoverSize: CGSize {
        clampedSize(base: Self.basePopoverSize)
    }

    public var developmentPanelSize: CGSize {
        clampedSize(base: Self.baseDevelopmentPanelSize)
    }

    public var settingsWindowSize: CGSize {
        clampedSize(base: Self.baseSettingsWindowSize)
    }

    public var settingsContentSize: CGSize {
        clampedSize(base: Self.baseSettingsContentSize)
    }

    public var aboutWindowSize: CGSize {
        clampedSize(base: Self.baseAboutWindowSize)
    }

    private static func quantize(_ value: CGFloat) -> CGFloat {
        (value * 100).rounded() / 100
    }
}

private struct DisplayScaleMetricsKey: EnvironmentKey {
    static let defaultValue: DisplayScaleMetrics = .standard
}

extension EnvironmentValues {
    public var displayScaleMetrics: DisplayScaleMetrics {
        get { self[DisplayScaleMetricsKey.self] }
        set { self[DisplayScaleMetricsKey.self] = newValue }
    }
}

/// Observable holder for a window/surface's current `DisplayScaleMetrics`.
@MainActor
public final class DisplayScaleController: ObservableObject {
    @Published public private(set) var metrics: DisplayScaleMetrics

    public init(metrics: DisplayScaleMetrics = .standard) {
        self.metrics = metrics
    }

    @discardableResult
    public func update(_ newMetrics: DisplayScaleMetrics) -> Bool {
        guard newMetrics != metrics else { return false }
        metrics = newMetrics
        return true
    }
}

/// Root wrapper for `NSHostingController` views that injects `controller.metrics` into SwiftUI's environment.
public struct ScaledHostingView<Content: View>: View {
    @ObservedObject private var controller: DisplayScaleController
    private let content: () -> Content

    public init(
        controller: DisplayScaleController,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.controller = controller
        self.content = content
    }

    public var body: some View {
        content()
            .environment(\.displayScaleMetrics, controller.metrics)
    }
}
