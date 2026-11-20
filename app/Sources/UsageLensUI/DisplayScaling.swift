import AppKit
import CoreGraphics
import SwiftUI

/// Immutable display-aware scaling metrics derived from a screen's physical and logical size.
///
/// Core math operates on plain `CGSize` values with zero `NSScreen` side effects so
/// unit tests and offscreen `ImageRenderer` checks are 100% deterministic.
public struct DisplayScaleMetrics: Equatable, Sendable {
    // 13.3" 16:10 MacBook reference baseline (~337.4 mm diagonal)
    public static let referenceDisplaySize = CGSize(width: 1440, height: 900)
    public static let referencePhysicalSizeMM = CGSize(width: 286, height: 179)

    // Physical vs logical blend and logarithmic response gains
    public static let physicalRatioWeight: CGFloat = 0.60
    public static let sizeCurveGain: CGFloat = 1.15
    public static let fontCurveGain: CGFloat = 1.00

    // Plausible EDID physical dimension bounds (10 cm .. 300 cm)
    public static let minValidPhysicalMillimeters: CGFloat = 100
    public static let maxValidPhysicalMillimeters: CGFloat = 3000

    // Scale clamps & readability floor
    public static let minSizeScale: CGFloat = 0.85
    public static let maxSizeScale: CGFloat = 1.60

    public static let minFontScale: CGFloat = 0.88
    public static let maxFontScale: CGFloat = 1.50
    public static let minimumFontSize: CGFloat = 8.5

    // Visible-frame safety ratios
    public static let maxVisibleWidthRatio: CGFloat = 0.90
    public static let maxVisibleHeightRatio: CGFloat = 0.85

    // Base (1.0x) surface sizes (Settings window and SettingsPanelView unified on 360 × 520)
    public static let basePopoverSize = CGSize(width: 340, height: 560)
    public static let baseDevelopmentPanelSize = CGSize(width: 368, height: 620)
    public static let baseSettingsWindowSize = CGSize(width: 360, height: 520)
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

    /// Validates EDID physical display dimensions in millimeters, rejecting nil, zero, negative,
    /// non-finite, or implausible (< 100 mm or > 3000 mm) values.
    public static func isValidPhysicalSize(_ size: CGSize?) -> Bool {
        guard let size,
              size.width.isFinite, size.height.isFinite,
              size.width >= minValidPhysicalMillimeters,
              size.height >= minValidPhysicalMillimeters,
              size.width <= maxValidPhysicalMillimeters,
              size.height <= maxValidPhysicalMillimeters else {
            return false
        }
        return true
    }

    /// Computes scaling metrics from logical display dimensions, optional usable visible area,
    /// and optional physical dimensions in millimeters.
    /// Falls back to `.standard` if `displaySize` is zero, negative, or non-finite.
    public static func make(
        displaySize: CGSize,
        visibleSize: CGSize? = nil,
        physicalSizeMM: CGSize? = nil
    ) -> DisplayScaleMetrics {
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

        let logicalRatio = min(
            displaySize.width / Self.referenceDisplaySize.width,
            displaySize.height / Self.referenceDisplaySize.height
        )

        let combinedRatio: CGFloat
        if let physicalSizeMM, Self.isValidPhysicalSize(physicalSizeMM) {
            let physicalRatio = min(
                physicalSizeMM.width / Self.referencePhysicalSizeMM.width,
                physicalSizeMM.height / Self.referencePhysicalSizeMM.height
            )
            let w = Self.physicalRatioWeight
            combinedRatio = CGFloat(
                pow(Double(physicalRatio), Double(w)) * pow(Double(logicalRatio), Double(1.0 - w))
            )
        } else {
            combinedRatio = logicalRatio
        }

        let logRatio = CGFloat(log(Double(combinedRatio)))
        let rawSizeScale = 1.0 + Self.sizeCurveGain * logRatio
        let rawFontScale = 1.0 + Self.fontCurveGain * logRatio

        let sizeScale = quantize(min(max(rawSizeScale, Self.minSizeScale), Self.maxSizeScale))
        let fontScale = quantize(min(max(rawFontScale, Self.minFontScale), Self.maxFontScale))

        return DisplayScaleMetrics(
            sizeScale: sizeScale,
            fontScale: fontScale,
            visibleSize: sanitizedVisibleSize
        )
    }

    /// Thin AppKit/CoreGraphics adapter reading `screen.frame.size`, `screen.visibleFrame.size`,
    /// and physical screen size in millimeters via `CGDisplayScreenSize`.
    public static func from(screen: NSScreen?) -> DisplayScaleMetrics {
        guard let screen else { return .standard }
        let physicalSizeMM: CGSize?
        if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let rawMM = CGDisplayScreenSize(displayID)
            physicalSizeMM = isValidPhysicalSize(rawMM) ? rawMM : nil
        } else {
            physicalSizeMM = nil
        }
        return make(
            displaySize: screen.frame.size,
            visibleSize: screen.visibleFrame.size,
            physicalSizeMM: physicalSizeMM
        )
    }

    /// Computes a center-preserving window frame constrained completely within `visibleFrame`
    /// so the title bar and all four edges remain visible after dynamic display resizes.
    public static func clampedWindowFrame(
        currentFrame: CGRect,
        targetFrameSize: CGSize,
        in visibleFrame: CGRect?
    ) -> CGRect {
        var width = targetFrameSize.width.rounded()
        var height = targetFrameSize.height.rounded()
        var originX = (currentFrame.midX - width / 2).rounded()
        var originY = (currentFrame.midY - height / 2).rounded()

        if let visibleFrame,
           visibleFrame.width.isFinite, visibleFrame.height.isFinite,
           visibleFrame.width > 0, visibleFrame.height > 0 {
            width = min(width, floor(visibleFrame.width))
            height = min(height, floor(visibleFrame.height))
            let minX = visibleFrame.minX
            let maxX = max(minX, visibleFrame.maxX - width)
            let minY = visibleFrame.minY
            let maxY = max(minY, visibleFrame.maxY - height)
            originX = min(max(originX, minX), maxX).rounded()
            originY = min(max(originY, minY), maxY).rounded()
        }

        return CGRect(x: originX, y: originY, width: width, height: height)
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
