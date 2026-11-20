import AppKit
import SwiftUI
import XCTest
@testable import UsageLensKit
@testable import UsageLensUI

final class DisplayScalingTests: XCTestCase {

    // MARK: - Baseline (Zero Regression)

    func testBaselineDisplayResolvesToOne() {
        let withEDID = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 900),
            physicalSizeMM: CGSize(width: 286, height: 179)
        )
        let withoutEDID = DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: 900))

        for metrics in [withEDID, withoutEDID] {
            XCTAssertEqual(metrics.sizeScale, 1.0)
            XCTAssertEqual(metrics.fontScale, 1.0)
            XCTAssertEqual(metrics.panelWidth, 340)
            XCTAssertEqual(metrics.popoverSize, CGSize(width: 340, height: 560))
            XCTAssertEqual(metrics.developmentPanelSize, CGSize(width: 368, height: 620))
            XCTAssertEqual(metrics.settingsWindowSize, CGSize(width: 360, height: 520))
            XCTAssertEqual(metrics.aboutWindowSize, CGSize(width: 280, height: 230))
            XCTAssertEqual(metrics.scaledFontSize(12), 12.0)
            XCTAssertEqual(metrics.scaledFontSize(14), 14.0)
            XCTAssertEqual(metrics.scaledFontSize(17), 17.0)
        }
    }

    // MARK: - Compact & 13"-14" Displays

    func testCompactAndFourteenInchDisplays() {
        let tiny = DisplayScaleMetrics.make(displaySize: CGSize(width: 800, height: 600))
        let small = DisplayScaleMetrics.make(displaySize: CGSize(width: 1024, height: 768))
        let air13EDID = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1280, height: 800),
            physicalSizeMM: CGSize(width: 286, height: 179)
        )
        let air13Logical = DisplayScaleMetrics.make(displaySize: CGSize(width: 1280, height: 800))
        let mbp14 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1512, height: 982),
            physicalSizeMM: CGSize(width: 302, height: 196)
        )

        XCTAssertEqual(tiny.sizeScale, DisplayScaleMetrics.minSizeScale)
        XCTAssertEqual(tiny.fontScale, DisplayScaleMetrics.minFontScale)

        XCTAssertEqual(small.sizeScale, DisplayScaleMetrics.minSizeScale)
        XCTAssertEqual(small.fontScale, DisplayScaleMetrics.minFontScale)
        XCTAssertEqual(small.panelWidth, 289)
        XCTAssertEqual(small.popoverSize, CGSize(width: 289, height: 476))

        XCTAssertLessThan(air13EDID.sizeScale, 1.0)
        XCTAssertLessThan(air13EDID.fontScale, 1.0)
        XCTAssertEqual(air13EDID.sizeScale, 0.95)
        XCTAssertEqual(air13EDID.fontScale, 0.95)
        XCTAssertEqual(air13EDID.panelWidth, 323)
        XCTAssertEqual(air13EDID.popoverSize, CGSize(width: 323, height: 532))

        XCTAssertLessThan(air13Logical.sizeScale, 1.0)
        XCTAssertGreaterThanOrEqual(air13Logical.sizeScale, DisplayScaleMetrics.minSizeScale)
        XCTAssertLessThan(air13Logical.fontScale, 1.0)
        XCTAssertGreaterThanOrEqual(air13Logical.fontScale, DisplayScaleMetrics.minFontScale)

        XCTAssertEqual(mbp14.sizeScale, 1.06)
        XCTAssertEqual(mbp14.fontScale, 1.05)
        XCTAssertEqual(mbp14.panelWidth, 360)
        XCTAssertEqual(mbp14.popoverSize, CGSize(width: 360, height: 594))

        XCTAssertLessThanOrEqual(tiny.sizeScale, small.sizeScale)
        XCTAssertLessThan(small.sizeScale, air13EDID.sizeScale)
        XCTAssertLessThan(air13EDID.sizeScale, mbp14.sizeScale)
    }

    func testMinimumFontSizeFloor() {
        let tiny = DisplayScaleMetrics.make(displaySize: CGSize(width: 800, height: 600))
        XCTAssertGreaterThanOrEqual(tiny.scaledFontSize(9.0), DisplayScaleMetrics.minimumFontSize)
        XCTAssertEqual(tiny.scaledFontSize(9.0), 8.5)
        XCTAssertEqual(tiny.scaledFontSize(6.0), 8.5)
    }

    // MARK: - 16-Inch MacBook Pro

    func testSixteenInchMacBookProScaling() {
        let mbp16 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1728, height: 1117),
            physicalSizeMM: CGSize(width: 345, height: 223)
        )
        XCTAssertEqual(mbp16.sizeScale, 1.21)
        XCTAssertTrue((1.20...1.25).contains(mbp16.sizeScale))
        XCTAssertEqual(mbp16.fontScale, 1.19)
        XCTAssertTrue((1.18...1.22).contains(mbp16.fontScale))
        XCTAssertEqual(mbp16.panelWidth, 411)
        XCTAssertTrue((410...425).contains(mbp16.panelWidth))
        XCTAssertEqual(mbp16.popoverSize, CGSize(width: 411, height: 678))

        let mbp16NoEDID = DisplayScaleMetrics.make(displaySize: CGSize(width: 1728, height: 1117))
        XCTAssertEqual(mbp16NoEDID.sizeScale, 1.21)
        XCTAssertTrue((1.20...1.25).contains(mbp16NoEDID.sizeScale))
        XCTAssertEqual(mbp16NoEDID.fontScale, 1.18)
        XCTAssertTrue((1.18...1.22).contains(mbp16NoEDID.fontScale))
        XCTAssertEqual(mbp16NoEDID.panelWidth, 411)
    }

    // MARK: - 27-Inch & 32-Inch External Monitors & Upper Bounds

    func testTwentySevenInchExternalMonitorsAcrossScalingModes() {
        let monitor27HiDPI = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1920, height: 1080),
            visibleSize: CGSize(width: 1920, height: 1020),
            physicalSizeMM: CGSize(width: 597, height: 336)
        )
        XCTAssertEqual(monitor27HiDPI.sizeScale, 1.52)
        XCTAssertTrue((1.45...1.60).contains(monitor27HiDPI.sizeScale))
        XCTAssertEqual(monitor27HiDPI.fontScale, 1.45)
        XCTAssertTrue((1.38...1.50).contains(monitor27HiDPI.fontScale))
        XCTAssertEqual(monitor27HiDPI.popoverSize.width, 517)
        XCTAssertTrue((490...545).contains(monitor27HiDPI.popoverSize.width))
        XCTAssertLessThanOrEqual(monitor27HiDPI.popoverSize.height, floor(1020 * DisplayScaleMetrics.maxVisibleHeightRatio))
        XCTAssertEqual(monitor27HiDPI.popoverSize.height, 851)

        let monitor27QHD = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 2560, height: 1440),
            physicalSizeMM: CGSize(width: 597, height: 336)
        )
        XCTAssertEqual(monitor27QHD.sizeScale, 1.60)
        XCTAssertEqual(monitor27QHD.fontScale, 1.50)
        XCTAssertEqual(monitor27QHD.popoverSize, CGSize(width: 544, height: 896))

        let monitor27Native4K = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 3840, height: 2160),
            physicalSizeMM: CGSize(width: 597, height: 336)
        )
        XCTAssertEqual(monitor27Native4K.sizeScale, 1.60)
        XCTAssertEqual(monitor27Native4K.fontScale, 1.50)
        XCTAssertEqual(monitor27Native4K.popoverSize, CGSize(width: 544, height: 896))
    }

    func testThirtyTwoInchDisplaysClampAtUpperBounds() {
        let monitor32HiDPI = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1920, height: 1080),
            visibleSize: CGSize(width: 1920, height: 1020),
            physicalSizeMM: CGSize(width: 708, height: 398)
        )
        let monitor32Scaled = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 3008, height: 1692),
            physicalSizeMM: CGSize(width: 708, height: 398)
        )
        let pro6k = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 6016, height: 3384),
            physicalSizeMM: CGSize(width: 708, height: 398)
        )

        XCTAssertEqual(monitor32HiDPI.sizeScale, DisplayScaleMetrics.maxSizeScale)
        XCTAssertEqual(monitor32HiDPI.fontScale, DisplayScaleMetrics.maxFontScale)
        XCTAssertEqual(monitor32HiDPI.popoverSize.height, 867)

        for metrics in [monitor32Scaled, pro6k] {
            XCTAssertEqual(metrics.sizeScale, DisplayScaleMetrics.maxSizeScale)
            XCTAssertEqual(metrics.fontScale, DisplayScaleMetrics.maxFontScale)
            XCTAssertEqual(metrics.panelWidth, 544)
        }
    }

    // MARK: - EDID Validation & Fallback

    func testInvalidPhysicalEDIDValuesFallBackToLogicalOnly() {
        let displaySize = CGSize(width: 2560, height: 1440)
        let expectedLogical = DisplayScaleMetrics.make(displaySize: displaySize, physicalSizeMM: nil)
        XCTAssertEqual(expectedLogical.sizeScale, 1.54)
        XCTAssertEqual(expectedLogical.fontScale, 1.47)

        let invalidSizes: [CGSize?] = [
            nil,
            .zero,
            CGSize(width: -597, height: 336),
            CGSize(width: 597, height: -336),
            CGSize(width: CGFloat.nan, height: 336),
            CGSize(width: 597, height: CGFloat.nan),
            CGSize(width: CGFloat.infinity, height: 336),
            CGSize(width: 597, height: CGFloat.infinity),
            CGSize(width: 16, height: 9),
            CGSize(width: 99, height: 179),
            CGSize(width: 5000, height: 3000),
            CGSize(width: 3001, height: 336),
        ]

        for invalid in invalidSizes {
            XCTAssertFalse(DisplayScaleMetrics.isValidPhysicalSize(invalid))
            let actual = DisplayScaleMetrics.make(displaySize: displaySize, physicalSizeMM: invalid)
            XCTAssertEqual(actual, expectedLogical)
        }

        XCTAssertTrue(DisplayScaleMetrics.isValidPhysicalSize(CGSize(width: 100, height: 100)))
        XCTAssertTrue(DisplayScaleMetrics.isValidPhysicalSize(CGSize(width: 597, height: 336)))
        XCTAssertTrue(DisplayScaleMetrics.isValidPhysicalSize(CGSize(width: 3000, height: 3000)))
    }

    // MARK: - Aspect-Ratio Safety (Ultrawide & Portrait)

    func testUltrawideDoesNotOverScale() {
        let qhd27 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 2560, height: 1440),
            physicalSizeMM: CGSize(width: 597, height: 336)
        )
        let ultrawide34 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 3440, height: 1440),
            physicalSizeMM: CGSize(width: 797, height: 334)
        )
        let superUltrawideLogical = DisplayScaleMetrics.make(displaySize: CGSize(width: 5120, height: 1440))
        let qhdLogical = DisplayScaleMetrics.make(displaySize: CGSize(width: 2560, height: 1440))

        XCTAssertEqual(ultrawide34.sizeScale, qhd27.sizeScale)
        XCTAssertEqual(ultrawide34.fontScale, qhd27.fontScale)
        XCTAssertEqual(ultrawide34.sizeScale, 1.60)
        XCTAssertEqual(ultrawide34.fontScale, 1.50)

        XCTAssertEqual(superUltrawideLogical.sizeScale, qhdLogical.sizeScale)
        XCTAssertEqual(superUltrawideLogical.fontScale, qhdLogical.fontScale)
    }

    func testPortraitIsConstrainedByNarrowerWidthAxis() {
        let portrait27 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 2560),
            visibleSize: CGSize(width: 1440, height: 2500),
            physicalSizeMM: CGSize(width: 336, height: 597)
        )
        let portrait1080 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1080, height: 1920),
            visibleSize: CGSize(width: 1080, height: 1860)
        )

        XCTAssertEqual(portrait27.sizeScale, 1.11)
        XCTAssertEqual(portrait27.fontScale, 1.10)
        XCTAssertEqual(portrait27.panelWidth, 377)
        XCTAssertLessThanOrEqual(portrait27.panelWidth, floor(1440 * DisplayScaleMetrics.maxVisibleWidthRatio))

        XCTAssertEqual(portrait1080.sizeScale, DisplayScaleMetrics.minSizeScale)
        XCTAssertEqual(portrait1080.fontScale, DisplayScaleMetrics.minFontScale)
        XCTAssertEqual(portrait1080.panelWidth, 289)
        XCTAssertLessThanOrEqual(portrait1080.panelWidth, floor(1080 * DisplayScaleMetrics.maxVisibleWidthRatio))
    }

    // MARK: - Visible Area Clamping

    func testVisibleSizeClamping() {
        let tinyTight = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 800, height: 600),
            visibleSize: CGSize(width: 800, height: 500)
        )
        XCTAssertLessThanOrEqual(tinyTight.popoverSize.width, floor(800 * DisplayScaleMetrics.maxVisibleWidthRatio))
        XCTAssertLessThanOrEqual(tinyTight.popoverSize.height, floor(500 * DisplayScaleMetrics.maxVisibleHeightRatio))
        XCTAssertEqual(tinyTight.popoverSize.height, 425)

        let monitor27TallDock = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1920, height: 1080),
            visibleSize: CGSize(width: 1920, height: 900),
            physicalSizeMM: CGSize(width: 597, height: 336)
        )
        XCTAssertEqual(monitor27TallDock.popoverSize.width, 517)
        XCTAssertEqual(monitor27TallDock.popoverSize.height, floor(900 * DisplayScaleMetrics.maxVisibleHeightRatio))

        let narrowVisible = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 900),
            visibleSize: CGSize(width: 300, height: 400)
        )
        XCTAssertEqual(narrowVisible.panelWidth, 270)
        XCTAssertEqual(narrowVisible.popoverSize, CGSize(width: 270, height: 340))
        XCTAssertEqual(narrowVisible.settingsWindowSize, CGSize(width: 270, height: 340))
        XCTAssertEqual(narrowVisible.aboutWindowSize, CGSize(width: 270, height: 230))
    }

    // MARK: - Window Frame Edge Clamping

    func testClampedWindowFrameConstrainsAllFourEdgesAndCorners() {
        let visible = CGRect(x: 0, y: 70, width: 2560, height: 1340) // maxX = 2560, maxY = 1410

        // Top-left edge (reproduces Round 1 review finding: title bar pushed above maxY & left < minX)
        let topLeft = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 50, y: 1182, width: 238, height: 228),
            targetFrameSize: CGSize(width: 353, height: 322),
            in: visible
        )
        XCTAssertGreaterThanOrEqual(topLeft.minX, visible.minX)
        XCTAssertLessThanOrEqual(topLeft.maxX, visible.maxX)
        XCTAssertGreaterThanOrEqual(topLeft.minY, visible.minY)
        XCTAssertLessThanOrEqual(topLeft.maxY, visible.maxY)
        XCTAssertEqual(topLeft.size, CGSize(width: 353, height: 322))

        // Top edge (menu bar)
        let topEdge = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 1000, y: 1200, width: 280, height: 210),
            targetFrameSize: CGSize(width: 448, height: 368),
            in: visible
        )
        XCTAssertEqual(topEdge.maxY, visible.maxY)
        XCTAssertGreaterThanOrEqual(topEdge.minY, visible.minY)

        // Bottom edge (Dock)
        let bottomEdge = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 1000, y: 72, width: 280, height: 230),
            targetFrameSize: CGSize(width: 448, height: 368),
            in: visible
        )
        XCTAssertEqual(bottomEdge.minY, visible.minY)
        XCTAssertLessThanOrEqual(bottomEdge.maxY, visible.maxY)

        // Left edge
        let leftEdge = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 4, y: 600, width: 280, height: 230),
            targetFrameSize: CGSize(width: 448, height: 368),
            in: visible
        )
        XCTAssertEqual(leftEdge.minX, visible.minX)

        // Right edge
        let rightEdge = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 2275, y: 600, width: 280, height: 230),
            targetFrameSize: CGSize(width: 448, height: 368),
            in: visible
        )
        XCTAssertEqual(rightEdge.maxX, visible.maxX)

        // Top-right corner
        let topRightCorner = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 2300, y: 1200, width: 260, height: 210),
            targetFrameSize: CGSize(width: 500, height: 420),
            in: visible
        )
        XCTAssertEqual(topRightCorner.maxX, visible.maxX)
        XCTAssertEqual(topRightCorner.maxY, visible.maxY)

        // Bottom-left corner
        let bottomLeftCorner = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 0, y: 70, width: 260, height: 210),
            targetFrameSize: CGSize(width: 500, height: 420),
            in: visible
        )
        XCTAssertEqual(bottomLeftCorner.minX, visible.minX)
        XCTAssertEqual(bottomLeftCorner.minY, visible.minY)

        // Oversized target frame clamps to visibleFrame dimensions
        let oversized = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 100, y: 100, width: 300, height: 300),
            targetFrameSize: CGSize(width: 3000, height: 2000),
            in: visible
        )
        XCTAssertEqual(oversized, visible)

        // nil visibleFrame preserves center without clamping
        let unclamped = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: CGRect(x: 50, y: 1182, width: 238, height: 228),
            targetFrameSize: CGSize(width: 353, height: 322),
            in: nil
        )
        XCTAssertEqual(unclamped.size, CGSize(width: 353, height: 322))
        XCTAssertEqual(unclamped.origin.x, (169 - 353.0 / 2).rounded())
        XCTAssertEqual(unclamped.origin.y, (1296 - 322.0 / 2).rounded())

        // Idempotency across repeated updates
        let repeated = DisplayScaleMetrics.clampedWindowFrame(
            currentFrame: topLeft,
            targetFrameSize: CGSize(width: 353, height: 322),
            in: visible
        )
        XCTAssertEqual(repeated, topLeft)
    }

    // MARK: - Invalid / Headless Fallback & Controller

    func testInvalidAndHeadlessInputsFallbackToStandard() {
        XCTAssertEqual(DisplayScaleMetrics.from(screen: nil), .standard)
        XCTAssertEqual(DisplayScaleMetrics.make(displaySize: .zero), .standard)
        XCTAssertEqual(DisplayScaleMetrics.make(displaySize: CGSize(width: -1440, height: 900)), .standard)
        XCTAssertEqual(DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: -900)), .standard)
        XCTAssertEqual(DisplayScaleMetrics.make(displaySize: CGSize(width: CGFloat.nan, height: 900)), .standard)
        XCTAssertEqual(DisplayScaleMetrics.make(displaySize: CGSize(width: CGFloat.infinity, height: 900)), .standard)
        XCTAssertEqual(DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: CGFloat.infinity)), .standard)
    }

    @MainActor
    func testDisplayScaleControllerDeduplicatesUpdates() {
        let controller = DisplayScaleController()
        XCTAssertEqual(controller.metrics, .standard)
        XCTAssertFalse(controller.update(.standard))

        let large = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1920, height: 1080),
            physicalSizeMM: CGSize(width: 597, height: 336)
        )
        XCTAssertTrue(controller.update(large))
        XCTAssertEqual(controller.metrics, large)
        XCTAssertFalse(controller.update(large))
    }

    // MARK: - Offscreen ImageRenderer & Unified Settings Sizing Verification

    @MainActor
    func testOffscreenRenderedViewsScaleAcrossFourDisplayProfiles() async throws {
        let compact = DisplayScaleMetrics.make(displaySize: CGSize(width: 1024, height: 768))
        let baseline = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 900),
            physicalSizeMM: CGSize(width: 286, height: 179)
        )
        let mbp16 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1728, height: 1117),
            physicalSizeMM: CGSize(width: 345, height: 223)
        )
        let monitor27 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1920, height: 1080),
            visibleSize: CGSize(width: 1920, height: 1020),
            physicalSizeMM: CGSize(width: 597, height: 336)
        )

        // 1. PanelView
        let store = UsageStore(
            provider: SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.codexReport()]]),
            refreshInterval: 3600,
            selected: ProviderCatalog.codex,
            autoStart: false
        )
        await store.refreshAll()

        let panelCompact = try renderImage(PanelView(store: store).environment(\.displayScaleMetrics, compact))
        let panelBaseline = try renderImage(PanelView(store: store).environment(\.displayScaleMetrics, baseline))
        let panelMBP16 = try renderImage(PanelView(store: store).environment(\.displayScaleMetrics, mbp16))
        let panelMonitor27 = try renderImage(PanelView(store: store).environment(\.displayScaleMetrics, monitor27))

        XCTAssertLessThan(panelCompact.width, panelBaseline.width)
        XCTAssertLessThan(panelBaseline.width, panelMBP16.width)
        XCTAssertLessThan(panelMBP16.width, panelMonitor27.width)
        XCTAssertLessThan(panelCompact.height, panelBaseline.height)
        XCTAssertLessThan(panelBaseline.height, panelMBP16.height)
        XCTAssertLessThan(panelMBP16.height, panelMonitor27.height)

        // 2. SettingsPanelView (including unified settingsWindowSize correspondence)
        let launchAtLogin = LaunchAtLoginManager()
        let settingsCompact = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, compact)
        )
        let settingsBaseline = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, baseline)
        )
        let settingsMBP16 = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, mbp16)
        )
        let settingsMonitor27 = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, monitor27)
        )

        XCTAssertLessThan(settingsCompact.width, settingsBaseline.width)
        XCTAssertLessThan(settingsBaseline.width, settingsMBP16.width)
        XCTAssertLessThan(settingsMBP16.width, settingsMonitor27.width)
        XCTAssertLessThan(settingsCompact.height, settingsBaseline.height)
        XCTAssertLessThan(settingsBaseline.height, settingsMBP16.height)
        XCTAssertLessThan(settingsMBP16.height, settingsMonitor27.height)

        let clampedTight = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 900),
            visibleSize: CGSize(width: 320, height: 400)
        )
        let settingsClamped = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, clampedTight)
        )

        for (image, profile) in [
            (settingsCompact, compact),
            (settingsBaseline, baseline),
            (settingsMBP16, mbp16),
            (settingsMonitor27, monitor27),
            (settingsClamped, clampedTight),
        ] {
            XCTAssertEqual(CGFloat(image.width), profile.settingsWindowSize.width, accuracy: 1.0)
            XCTAssertEqual(CGFloat(image.height), profile.settingsWindowSize.height, accuracy: 1.0)
        }

        // 3. AboutPanelView
        let aboutCompact = try renderImage(AboutPanelView().environment(\.displayScaleMetrics, compact))
        let aboutBaseline = try renderImage(AboutPanelView().environment(\.displayScaleMetrics, baseline))
        let aboutMBP16 = try renderImage(AboutPanelView().environment(\.displayScaleMetrics, mbp16))
        let aboutMonitor27 = try renderImage(AboutPanelView().environment(\.displayScaleMetrics, monitor27))

        XCTAssertLessThan(aboutCompact.width, aboutBaseline.width)
        XCTAssertLessThan(aboutBaseline.width, aboutMBP16.width)
        XCTAssertLessThan(aboutMBP16.width, aboutMonitor27.width)
        XCTAssertLessThan(aboutCompact.height, aboutBaseline.height)
        XCTAssertLessThan(aboutBaseline.height, aboutMBP16.height)
        XCTAssertLessThan(aboutMBP16.height, aboutMonitor27.height)
    }

    @MainActor
    private func renderImage(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.cgImage else {
            throw XCTSkip("ImageRenderer unavailable in current environment")
        }
        return image
    }
}
