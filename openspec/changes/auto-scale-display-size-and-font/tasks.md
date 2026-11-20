# Implementation Tasks: auto-scale-display-size-and-font

## 1. Core Display Scaling Model (`UsageLensUI`)
- [ ] Create `app/Sources/UsageLensUI/DisplayScaling.swift` implementing:
  - `DisplayScaleMetrics` (`Equatable`, `Sendable`) with `referenceDisplaySize` (`1440 × 900`), `minSizeScale` (`0.85`), `maxSizeScale` (`1.35`), `minFontScale` (`0.88`), `maxFontScale` (`1.30`), `minimumFontSize` (`8.5`), and `maxVisibleWidthRatio` (`0.90`) / `maxVisibleHeightRatio` (`0.85`).
  - `DisplayScaleMetrics.make(displaySize:visibleSize:)` implementing `min(w/1440, h/900)` + `sqrt` damping + `0.01` quantization + invalid/non-finite fallback to `.standard`.
  - `DisplayScaleMetrics.from(screen: NSScreen?)` reading `screen?.frame.size` and `screen?.visibleFrame.size` with `.standard` fallback when `screen == nil`.
  - Scaling helpers: `scaledDimension(_:minimum:)`, `scaledSpacing(_:minimum:)`, `scaledFontSize(_:minimum:)`, `font(_:weight:)`, `clampedSize(base:)`, and convenience properties (`panelWidth`, `popoverSize`, `developmentPanelSize`, `settingsWindowSize`, `settingsContentSize`, `aboutWindowSize`).
  - SwiftUI `EnvironmentValues.displayScaleMetrics` (defaulting to `.standard`).
  - `@MainActor public final class DisplayScaleController: ObservableObject` and `public struct ScaledHostingView<Content: View>: View` to inject `controller.metrics` into `NSHostingController` roots.

## 2. Scale SwiftUI Views (`UsageLensUI`)
- [ ] Update `app/Sources/UsageLensUI/Theme.swift`:
  - Update `CardBackground` to read `@Environment(\.displayScaleMetrics)` and scale its `cornerRadius` via `metrics.scaledSpacing(corner)`.
- [ ] Update `app/Sources/UsageLensUI/PanelView.swift`:
  - Propagate `@Environment(\.displayScaleMetrics)` through `PanelView`, `ProviderTabBar`, `ProviderDetailView`, `WindowRowView`, `ProgressTrack`, `MetricTile`, and `FooterBar`.
  - Replace hardcoded `Theme.panelWidth`, font sizes, paddings, spacings, dot/icon frames, corner radii, and `ProgressTrack` height with `metrics` helpers while keeping existing `PanelView.init` signature source-compatible.
- [ ] Update `app/Sources/UsageLensUI/SettingsPanelView.swift`:
  - Read `@Environment(\.displayScaleMetrics)` and scale root `.frame(width:height:)`, paddings, spacings, theme accent circle, card corner radii, and all font sizes.
- [ ] Update `app/Sources/UsageLensUI/AboutPanelView.swift`:
  - Read `@Environment(\.displayScaleMetrics)` and scale root `.frame(width:height:)`, spacings, enlarged `MenuBarIconImage` frame, and all font sizes.

## 3. AppKit Window Sizing & Dynamic Display Observation (`UsageLens`)
- [ ] Update `app/Sources/UsageLens/UsageLensApp.swift`:
  - Add `DisplayScaleController` instances for `popover`, `developmentPanel`, `settingsPanel`, and `aboutPanel`.
  - Add `activeStatusScreen()` helper (`statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first`).
  - In `togglePopover(_:)`, compute `DisplayScaleMetrics.from(screen: activeStatusScreen())`, update `popoverScaleController`, set `popover.contentSize = metrics.popoverSize`, and wrap `panelView` in `ScaledHostingView`.
  - In `showDevelopmentPanel()`, `showSettings()`, and `showAbout()`, size new and re-opened windows using `DisplayScaleMetrics` from the active/window screen, wrap root views with `ScaledHostingView`, and sync `panel.appearance = UsageLensTheme.appkitAppearance`.
  - Observe `NSApplication.didChangeScreenParametersNotification` and `NSWindow.didChangeScreenNotification` (for Settings, About, Development windows) to dynamically update metrics and resize open windows via `resizeWindowPreservingCenter(_:to:)` without resize loops.
  - Clean up notification observers in `applicationWillTerminate(_:)`.
  - Leave `NSStatusItem` (`withLength: 32`) and `MenuBarIcon` (`24 × 20`) unchanged.

## 4. Unit & Offscreen Render Tests (`UsageLensUITests`)
- [ ] Create `app/Tests/UsageLensUITests/DisplayScalingTests.swift`:
  - Test baseline (`1440 × 900`), compact (`1280 × 800`, `1024 × 768`, `800 × 600`), and large (`1728 × 1117`, `2560 × 1440`, `3840 × 2160`) scale factors and bounds.
  - Test ultrawide (`3440 × 1440`) and portrait (`1080 × 1920`) aspect-ratio safety.
  - Test minimum font size floor (`>= 8.5pt`) and `visibleSize` clamping (`<= 90%` width, `<= 85%` height).
  - Test invalid/headless inputs (`nil` screen, `.zero`, negative, `.nan`, `.infinity`) fall back to `.standard`.
  - Test `ImageRenderer` offscreen rendering of `PanelView`, `SettingsPanelView`, and `AboutPanelView` across small, standard, and large `DisplayScaleMetrics`, asserting `small < standard < large` image dimensions.

## 5. Local Verification Commands
- [ ] Run Swift build and full Swift test suite:
  ```bash
  cd app && swift build && swift test
  ```
- [ ] Verify existing Python probe tests remain green:
  ```bash
  python3 -m unittest discover -s tests
  ```
- [ ] Verify `git status` and `git diff` contain only intended changes with no leftover debug artifacts.
