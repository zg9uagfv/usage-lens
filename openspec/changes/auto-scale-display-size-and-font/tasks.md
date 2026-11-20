# Implementation Tasks: auto-scale-display-size-and-font

## 1. Core Display Scaling Model (`UsageLensUI`) — Round 2 Physical + Logical Recalibration
- [x] Update `app/Sources/UsageLensUI/DisplayScaling.swift`:
  - Add physical reference constants `referencePhysicalSizeMM` (`286 × 179 mm`), `physicalRatioWeight` (`0.60`), `sizeCurveGain` (`1.15`), `fontCurveGain` (`1.00`), and EDID sanity bounds `minValidPhysicalMillimeters` (`100`) / `maxValidPhysicalMillimeters` (`3000`).
  - Raise upper bounds to `maxSizeScale = 1.60` and `maxFontScale = 1.50` (keeping `minSizeScale = 0.85`, `minFontScale = 0.88`, `minimumFontSize = 8.5`, `maxVisibleWidthRatio = 0.90`, `maxVisibleHeightRatio = 0.85`).
  - Add `DisplayScaleMetrics.isValidPhysicalSize(_:)` to reject `nil`, `.zero`, negative, non-finite, `< 100 mm`, or `> 3000 mm` EDID values.
  - Update `DisplayScaleMetrics.make(displaySize:visibleSize:physicalSizeMM:)` (defaulting `physicalSizeMM: CGSize? = nil` for source compatibility) to:
    1. Compute axis-safe `logicalRatio = min(w/1440, h/900)`.
    2. When `isValidPhysicalSize(physicalSizeMM)` holds, compute axis-safe `physicalRatio = min(mmW/286, mmH/179)` and blend via weighted geometric mean `pow(physicalRatio, 0.60) * pow(logicalRatio, 0.40)`; otherwise fall back to `logicalRatio`.
    3. Compute `sizeScale = quantize(clamp(1.0 + 1.15 * log(combinedRatio), 0.85, 1.60))` and `fontScale = quantize(clamp(1.0 + 1.00 * log(combinedRatio), 0.88, 1.50))`.
  - Update `DisplayScaleMetrics.from(screen: NSScreen?)` to extract `CGDirectDisplayID` from `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`, query `CGDisplayScreenSize(displayID)`, validate via `isValidPhysicalSize`, and pass `physicalSizeMM` to `make(...)`.
  - Remove the divergent `baseSettingsContentSize` / `settingsContentSize` (`340 × 480`) and unify on `baseSettingsWindowSize` (`360 × 520`) / `settingsWindowSize`.
  - Add pure `DisplayScaleMetrics.clampedWindowFrame(currentFrame:targetFrameSize:in:)` helper that centers the resized frame and clamps all four edges (`minX`, `maxX`, `minY`, `maxY`) inside `visibleFrame` so the title bar/close button never moves offscreen.
  - Keep existing scaling helpers (`scaledDimension`, `scaledSpacing`, `scaledFontSize`, `font`, `clampedSize`, convenience surface size properties), `EnvironmentValues.displayScaleMetrics`, `DisplayScaleController`, and `ScaledHostingView` intact.

## 2. Scale SwiftUI Views (`UsageLensUI`)
- [x] Verify `app/Sources/UsageLensUI/Theme.swift`:
  - `CardBackground` reads `@Environment(\.displayScaleMetrics)` and scales `cornerRadius` via `metrics.scaledSpacing(corner)`.
- [x] Verify `app/Sources/UsageLensUI/PanelView.swift`:
  - All subviews (`PanelView`, `ProviderTabBar`, `ProviderDetailView`, `WindowRowView`, `ProgressTrack`, `MetricTile`, `FooterBar`) scale cleanly up to `1.60x` size / `1.50x` font with no truncation or clipping.
- [x] Update `app/Sources/UsageLensUI/SettingsPanelView.swift` & verify `app/Sources/UsageLensUI/AboutPanelView.swift`:
  - Update `SettingsPanelView`'s root `.frame(width:height:alignment:)` to use `metrics.settingsWindowSize` (unified `360 × 520` base, matching `UsageLensApp.swift`'s `settingsPanel` content size across all scales and `visibleFrame` clamps).
  - Verify paddings, spacings, icons, and all fonts scale cleanly across `0.85x–1.60x` without clipping (including clamped `visibleFrame` heights on 27" `1920 × 1080` HiDPI).

## 3. AppKit Window Sizing & Dynamic Display Observation (`UsageLens`)
- [x] Update `app/Sources/UsageLens/UsageLensApp.swift`:
  - `activeStatusScreen()` and window screen observers pass the live `NSScreen` to `DisplayScaleMetrics.from(screen:)` so switching between a 16" MacBook screen and a 27" external monitor immediately updates `popover.contentSize`, window frames, and `DisplayScaleController` metrics.
  - Update `resizeWindowPreservingCenter(_:to:on:)` to route through `DisplayScaleMetrics.clampedWindowFrame(currentFrame:targetFrameSize:in:)` so dynamic resizes near any screen edge keep the full window frame (including title bar and close button) inside the target screen's `visibleFrame`, skipping no-op updates (`< 1pt` delta in origin and size) to prevent resize loops.
  - `NSStatusItem` (`withLength: 32`) and `MenuBarIcon` (`24 × 20`) remain unchanged.

## 4. Unit & Offscreen Render Tests (`UsageLensUITests`)
- [x] Update `app/Tests/UsageLensUITests/DisplayScalingTests.swift`:
  - Baseline (`1440 × 900` with `286 × 179 mm` and with `physicalSizeMM: nil`) → `1.00 / 1.00`, exact base sizes.
  - Compact 13"–14" displays (`800 × 600`, `1024 × 768`, `1280 × 800` + `286 × 179 mm`, `1512 × 982` + `302 × 196 mm`) → lower bounds (`0.85 / 0.88`) and balanced 14" sizing (`1.06 / 1.05`).
  - 16.2" MacBook Pro (`1728 × 1117` + `345 × 223 mm`) → `sizeScale == 1.21`, `fontScale == 1.19`, `panelWidth == 411pt`; and `physicalSizeMM: nil` fallback → `sizeScale == 1.21`, `fontScale == 1.18`.
  - 27" external monitors (`597 × 336 mm`):
    - `1920 × 1080` HiDPI (with `visibleSize: 1920 × 1020`) → `sizeScale == 1.52`, `fontScale == 1.45`, `popoverSize.width == 517pt`, height safely clamped `<= 85%` of `visibleSize.height`.
    - `2560 × 1440` QHD/5K → `sizeScale == 1.60`, `fontScale == 1.50`, `popoverSize.width == 544pt`.
    - `3840 × 2160` 4K Native → `sizeScale == 1.60`, `fontScale == 1.50`, `popoverSize.width == 544pt`.
  - 32" 4K/6K (`3008 × 1692`, `6016 × 3384`, `708 × 398 mm`) → clamped at `maxSizeScale == 1.60`, `maxFontScale == 1.50`.
  - EDID fallback tests: `physicalSizeMM` of `nil`, `.zero`, negative, `.nan`, `.infinity`, `16 × 9 mm`, and `5000 × 3000 mm` all fall back cleanly to logical-only scaling.
  - Ultrawide (`3440 × 1440`, `797 × 334 mm`) and Portrait (`1440 × 2560`, `336 × 597 mm`; `1080 × 1920`, `nil`) aspect-ratio safety tests.
  - Minimum font floor (`>= 8.5pt`), `visibleSize` clamping (`<= 90%` width, `<= 85%` height), and invalid/headless logical inputs (`nil` screen, `.zero`, negative, `.nan`, `.infinity`).
  - Window frame clamping tests (`DisplayScaleMetrics.clampedWindowFrame`): test all four edges (top/menu bar, bottom/Dock, left, right), corner clamping, oversized frame clamping, `visibleFrame == nil` pass-through, and repeated-update idempotency.
  - Settings unified size tests: assert `SettingsPanelView` rendered dimensions match `metrics.settingsWindowSize` across compact, baseline, 16" MBP, and 27" monitor scales (including clamped `visibleSize`).
  - `ImageRenderer` offscreen rendering of `PanelView`, `SettingsPanelView`, and `AboutPanelView` across compact (`1024 × 768`), baseline (`1440 × 900`), 16" MBP (`1728 × 1117`, `345 × 223 mm`), and 27" monitor (`1920 × 1080`, `597 × 336 mm`), asserting `compact < baseline < mbp16 < monitor27` image dimensions.

## 5. Local Verification Commands
- [x] Run Swift build and full Swift test suite:
  ```bash
  cd app && swift build && swift test
  ```
- [x] Verify existing Python probe tests remain green:
  ```bash
  python3 -m unittest discover -s tests
  ```
- [x] Verify `git status` and `git diff` contain only intended changes with no leftover debug artifacts.
