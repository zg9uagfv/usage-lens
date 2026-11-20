import AppKit
import SwiftUI
import XCTest
@testable import UsageLensKit
@testable import UsageLensUI

final class DisplayScalingTests: XCTestCase {

    // MARK: - Baseline (Zero Regression)

    func testBaselineDisplayResolvesToOne() {
        let metrics = DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(metrics.sizeScale, 1.0)
        XCTAssertEqual(metrics.fontScale, 1.0)
        XCTAssertEqual(metrics.panelWidth, 340)
        XCTAssertEqual(metrics.popoverSize, CGSize(width: 340, height: 560))
        XCTAssertEqual(metrics.developmentPanelSize, CGSize(width: 368, height: 620))
        XCTAssertEqual(metrics.settingsWindowSize, CGSize(width: 360, height: 520))
        XCTAssertEqual(metrics.settingsContentSize, CGSize(width: 340, height: 480))
        XCTAssertEqual(metrics.aboutWindowSize, CGSize(width: 280, height: 230))
        XCTAssertEqual(metrics.scaledFontSize(12), 12.0)
        XCTAssertEqual(metrics.scaledFontSize(14), 14.0)
        XCTAssertEqual(metrics.scaledFontSize(17), 17.0)
    }

    // MARK: - Compact / Small Displays & Lower Bounds

    func testCompactDisplaysScaleDownAndClamp() {
        let air13 = DisplayScaleMetrics.make(displaySize: CGSize(width: 1280, height: 800))
        let small = DisplayScaleMetrics.make(displaySize: CGSize(width: 1024, height: 768))
        let tiny = DisplayScaleMetrics.make(displaySize: CGSize(width: 800, height: 600))

        XCTAssertLessThan(air13.sizeScale, 1.0)
        XCTAssertLessThan(air13.fontScale, 1.0)
        XCTAssertEqual(air13.sizeScale, 0.94)
        XCTAssertEqual(air13.fontScale, 0.94)
        XCTAssertEqual(air13.panelWidth, 320)
        XCTAssertEqual(air13.popoverSize, CGSize(width: 320, height: 526))

        XCTAssertEqual(small.sizeScale, DisplayScaleMetrics.minSizeScale)
        XCTAssertEqual(small.fontScale, DisplayScaleMetrics.minFontScale)
        XCTAssertEqual(small.panelWidth, 289)
        XCTAssertEqual(small.popoverSize, CGSize(width: 289, height: 476))

        XCTAssertEqual(tiny.sizeScale, DisplayScaleMetrics.minSizeScale)
        XCTAssertEqual(tiny.fontScale, DisplayScaleMetrics.minFontScale)
        XCTAssertLessThanOrEqual(small.sizeScale, air13.sizeScale)
        XCTAssertLessThanOrEqual(tiny.sizeScale, small.sizeScale)
    }

    func testMinimumFontSizeFloor() {
        let tiny = DisplayScaleMetrics.make(displaySize: CGSize(width: 800, height: 600))
        XCTAssertGreaterThanOrEqual(tiny.scaledFontSize(9.0), DisplayScaleMetrics.minimumFontSize)
        XCTAssertEqual(tiny.scaledFontSize(9.0), 8.5)
        XCTAssertEqual(tiny.scaledFontSize(6.0), 8.5)
    }

    // MARK: - Large Displays & Upper Bounds

    func testLargeDisplaysScaleUpMonotonicallyAndClamp() {
        let baseline = DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: 900))
        let mbp16 = DisplayScaleMetrics.make(displaySize: CGSize(width: 1728, height: 1117))
        let qhd27 = DisplayScaleMetrics.make(displaySize: CGSize(width: 2560, height: 1440))
        let uhd4k = DisplayScaleMetrics.make(displaySize: CGSize(width: 3840, height: 2160))
        let pro6k = DisplayScaleMetrics.make(displaySize: CGSize(width: 6016, height: 3384))

        XCTAssertGreaterThan(mbp16.sizeScale, baseline.sizeScale)
        XCTAssertGreaterThan(qhd27.sizeScale, mbp16.sizeScale)
        XCTAssertGreaterThan(uhd4k.sizeScale, qhd27.sizeScale)

        XCTAssertEqual(mbp16.sizeScale, 1.10)
        XCTAssertEqual(qhd27.sizeScale, 1.26)
        XCTAssertEqual(qhd27.fontScale, 1.26)
        XCTAssertEqual(qhd27.panelWidth, 428)
        XCTAssertEqual(qhd27.popoverSize, CGSize(width: 428, height: 706))

        XCTAssertEqual(uhd4k.sizeScale, DisplayScaleMetrics.maxSizeScale)
        XCTAssertEqual(uhd4k.fontScale, DisplayScaleMetrics.maxFontScale)
        XCTAssertEqual(pro6k.sizeScale, DisplayScaleMetrics.maxSizeScale)
        XCTAssertEqual(pro6k.fontScale, DisplayScaleMetrics.maxFontScale)
    }

    // MARK: - Aspect-Ratio Safety (Ultrawide & Portrait)

    func testUltrawideDoesNotOverScale() {
        let qhd = DisplayScaleMetrics.make(displaySize: CGSize(width: 2560, height: 1440))
        let ultrawide = DisplayScaleMetrics.make(displaySize: CGSize(width: 3440, height: 1440))
        let superUltrawide = DisplayScaleMetrics.make(displaySize: CGSize(width: 5120, height: 1440))

        XCTAssertEqual(ultrawide.sizeScale, qhd.sizeScale)
        XCTAssertEqual(ultrawide.fontScale, qhd.fontScale)
        XCTAssertEqual(superUltrawide.sizeScale, qhd.sizeScale)
        XCTAssertEqual(superUltrawide.fontScale, qhd.fontScale)
    }

    func testPortraitIsConstrainedByNarrowerWidthAxis() {
        let portrait1080 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1080, height: 1920),
            visibleSize: CGSize(width: 1080, height: 1860)
        )
        let portrait1440 = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 2560),
            visibleSize: CGSize(width: 1440, height: 2500)
        )

        // 1080 / 1440 = 0.75 -> sqrt(0.75) ≈ 0.866 -> sizeScale 0.87, fontScale 0.88
        XCTAssertLessThan(portrait1080.sizeScale, 1.0)
        XCTAssertEqual(portrait1080.sizeScale, 0.87)
        XCTAssertEqual(portrait1080.fontScale, 0.88)
        XCTAssertLessThanOrEqual(portrait1080.panelWidth, floor(1080 * DisplayScaleMetrics.maxVisibleWidthRatio))

        // 1440 / 1440 = 1.0 -> baseline 1.0 despite tall height
        XCTAssertEqual(portrait1440.sizeScale, 1.0)
        XCTAssertEqual(portrait1440.fontScale, 1.0)
    }

    // MARK: - Visible Area Clamping

    func testVisibleSizeClamping() {
        let metrics = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 800, height: 600),
            visibleSize: CGSize(width: 800, height: 500)
        )
        XCTAssertLessThanOrEqual(metrics.popoverSize.width, floor(800 * DisplayScaleMetrics.maxVisibleWidthRatio))
        XCTAssertLessThanOrEqual(metrics.popoverSize.height, floor(500 * DisplayScaleMetrics.maxVisibleHeightRatio))
        XCTAssertEqual(metrics.popoverSize.height, 425)

        let narrowVisible = DisplayScaleMetrics.make(
            displaySize: CGSize(width: 1440, height: 900),
            visibleSize: CGSize(width: 300, height: 400)
        )
        XCTAssertEqual(narrowVisible.panelWidth, 270)
        XCTAssertEqual(narrowVisible.popoverSize, CGSize(width: 270, height: 340))
        XCTAssertEqual(narrowVisible.settingsWindowSize, CGSize(width: 270, height: 340))
        XCTAssertEqual(narrowVisible.aboutWindowSize, CGSize(width: 270, height: 230))
    }

    // MARK: - Invalid / Headless Fallback

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

        let large = DisplayScaleMetrics.make(displaySize: CGSize(width: 2560, height: 1440))
        XCTAssertTrue(controller.update(large))
        XCTAssertEqual(controller.metrics, large)
        XCTAssertFalse(controller.update(large))
    }

    // MARK: - Offscreen ImageRenderer Verification

    @MainActor
    func testOffscreenRenderedViewsScaleAcrossDisplayProfiles() async throws {
        let small = DisplayScaleMetrics.make(displaySize: CGSize(width: 1024, height: 768))
        let standard = DisplayScaleMetrics.make(displaySize: CGSize(width: 1440, height: 900))
        let large = DisplayScaleMetrics.make(displaySize: CGSize(width: 2560, height: 1440))

        // 1. PanelView
        let store = UsageStore(
            provider: SequencedProbeProvider([ProviderCatalog.codex: [Fixtures.codexReport()]]),
            refreshInterval: 3600,
            selected: ProviderCatalog.codex,
            autoStart: false
        )
        await store.refreshAll()

        let panelSmall = try renderImage(PanelView(store: store).environment(\.displayScaleMetrics, small))
        let panelStandard = try renderImage(PanelView(store: store).environment(\.displayScaleMetrics, standard))
        let panelLarge = try renderImage(PanelView(store: store).environment(\.displayScaleMetrics, large))

        XCTAssertLessThan(panelSmall.width, panelStandard.width)
        XCTAssertLessThan(panelStandard.width, panelLarge.width)
        XCTAssertLessThan(panelSmall.height, panelStandard.height)
        XCTAssertLessThan(panelStandard.height, panelLarge.height)

        // 2. SettingsPanelView
        let launchAtLogin = LaunchAtLoginManager()
        let settingsSmall = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, small)
        )
        let settingsStandard = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, standard)
        )
        let settingsLarge = try renderImage(
            SettingsPanelView(launchAtLogin: launchAtLogin, hasSavedAPIKey: false)
                .environment(\.displayScaleMetrics, large)
        )

        XCTAssertLessThan(settingsSmall.width, settingsStandard.width)
        XCTAssertLessThan(settingsStandard.width, settingsLarge.width)
        XCTAssertLessThan(settingsSmall.height, settingsStandard.height)
        XCTAssertLessThan(settingsStandard.height, settingsLarge.height)

        // 3. AboutPanelView
        let aboutSmall = try renderImage(AboutPanelView().environment(\.displayScaleMetrics, small))
        let aboutStandard = try renderImage(AboutPanelView().environment(\.displayScaleMetrics, standard))
        let aboutLarge = try renderImage(AboutPanelView().environment(\.displayScaleMetrics, large))

        XCTAssertLessThan(aboutSmall.width, aboutStandard.width)
        XCTAssertLessThan(aboutStandard.width, aboutLarge.width)
        XCTAssertLessThan(aboutSmall.height, aboutStandard.height)
        XCTAssertLessThan(aboutStandard.height, aboutLarge.height)
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
