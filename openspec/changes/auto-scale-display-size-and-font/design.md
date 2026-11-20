# Technical Design: Auto-Scale Display Size and Font

## 1. Architecture Overview

The feature is structured into three cleanly separated layers, adhering strictly to the zero-third-party-dependency constraint (`SwiftUI`, `AppKit`, `CoreGraphics`, `Foundation` only):

1. **Pure Scaling Model (`UsageLensUI/DisplayScaling.swift`)**:
   - `DisplayScaleMetrics`: An immutable `Equatable, Sendable` value type that computes `sizeScale`, `fontScale`, scaled dimensions, scaled font sizes, and clamped window/popover sizes from raw `CGSize` inputs (`displaySize`, `visibleSize`, and optional `physicalSizeMM`). Contains zero `NSScreen` / CoreGraphics side effects in its core math so unit tests are 100% deterministic.
   - `DisplayScaleMetrics.from(screen: NSScreen?)`: Thin AppKit/CoreGraphics adapter reading `screen.frame.size`, `screen.visibleFrame.size`, and physical screen size in millimeters via `CGDisplayScreenSize(displayID)` (using `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`), with safe EDID validation and `.standard` fallback when `screen == nil`.
   - `DisplayScaleController` (`@MainActor ObservableObject`): Holds `@Published public var metrics: DisplayScaleMetrics` per window/surface so dynamic screen changes trigger immediate SwiftUI updates.
   - SwiftUI `@Environment(\.displayScaleMetrics)`: Propagates `DisplayScaleMetrics` down the view tree without breaking any existing `init` signatures.

2. **Scaled SwiftUI Views (`UsageLensUI`)**:
   - `Theme.swift`: Keep existing base constants (`Theme.panelWidth = 340`, `Theme.cardCorner = 10`, `Theme.barHeight = 6`) as the `1.0x` reference values; update `CardBackground` to scale its corner radius via `@Environment(\.displayScaleMetrics)`.
   - `PanelView.swift`, `SettingsPanelView.swift`, `AboutPanelView.swift`: Read `@Environment(\.displayScaleMetrics) private var metrics` and route all container frames, font sizes, paddings, spacings, icon frames, and corner radii through `metrics.scaledDimension(_:)` / `metrics.scaledSpacing(_:)` / `metrics.font(_:weight:)`.

3. **AppKit Window & Display Observer (`UsageLens/UsageLensApp.swift`)**:
   - Track active `DisplayScaleController` instances for `popover`, `developmentPanel`, `settingsPanel`, and `aboutPanel`.
   - On `togglePopover(_:)`, resolve `let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first`, update popover controller metrics + `popover.contentSize` before `popover.show(...)`.
   - Subscribe to `NSApplication.didChangeScreenParametersNotification` and `NSWindow.didChangeScreenNotification` (for Settings, About, Development panels) to recompute `DisplayScaleMetrics` and resize open windows smoothly.

---

## 2. Scaling Formula & Clamping Bounds (Round 2 Recalibration)

### 2.1 Why Round 1 Under-Scaled & How Round 2 Fixes It

Round 1 used `sqrt(min(w/1440, h/900))` capped at `1.35x` size / `1.30x` font with no physical size awareness. That produced only `1.10x` (`374pt`) on a 16.2" MacBook Pro (`1728 × 1117`) and only `1.10x` (`374pt`) on a 27" 4K monitor running macOS's default `1920 × 1080` HiDPI mode (or `1.26x` on `2560 × 1440`).

Round 2 fixes this with two principled improvements:
1. **Combine physical size (`CGDisplayScreenSize`) with logical size**: Blend the axis-safe physical ratio (`min(mmW/286, mmH/179)`, referenced to a 13.3" 16:10 MacBook panel) and the axis-safe logical ratio (`min(w/1440, h/900)`) via a weighted geometric mean (`physicalWeight = 0.60`, `logicalWeight = 0.40`). This immediately recognizes a 27" monitor (`597 × 336 mm`) even when macOS runs it at `1920 × 1080` HiDPI, while still respecting logical workspace density and preserving full aspect-ratio safety on ultrawide and portrait displays.
2. **Replace overly aggressive `sqrt` damping with a calibrated logarithmic curve & raised caps**:
   - `rawSizeScale = 1.0 + 1.15 * log(combinedRatio)` (clamped to `[0.85, 1.60]`)
   - `rawFontScale = 1.0 + 1.00 * log(combinedRatio)` (clamped to `[0.88, 1.50]`)
   - At `combinedRatio == 1.0`, `log(1.0) == 0`, giving exact `1.00x` at the 13.3" baseline.
   - Around `1.20` (16" MacBook Pro), the slope delivers a noticeable `1.21x` size / `1.19x` font (`411pt` width).
   - Around `1.57–2.07` (27" desktop monitors across 1080p HiDPI, 1440p QHD/5K, and 4K), natural-log concavity smoothly brings scaling into `1.52x–1.60x` size / `1.45x–1.50x` font (`517–544pt` width) without runaway growth on 32" 6K displays.

### 2.2 Reference Constants

```swift
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

    // Base (1.0x) surface sizes
    public static let basePopoverSize = CGSize(width: 340, height: 560)
    public static let baseDevelopmentPanelSize = CGSize(width: 368, height: 620)
    public static let baseSettingsWindowSize = CGSize(width: 360, height: 520)
    public static let baseSettingsContentSize = CGSize(width: 340, height: 480)
    public static let baseAboutWindowSize = CGSize(width: 280, height: 230)
}
```

### 2.3 Exact Calculation (`DisplayScaleMetrics.make(displaySize:visibleSize:physicalSizeMM:)`)

1. **Logical input validation (headless/invalid guard)**:
   - If `!displaySize.width.isFinite || !displaySize.height.isFinite || displaySize.width <= 0 || displaySize.height <= 0`, return `.standard` (`sizeScale = 1.0`, `fontScale = 1.0`, `visibleSize = nil`).
2. **Axis-safe logical ratio**:
   ```swift
   let logicalRatio = min(
       displaySize.width / Self.referenceDisplaySize.width,
       displaySize.height / Self.referenceDisplaySize.height
   )
   ```
3. **Optional EDID physical ratio & weighted geometric blend**:
   ```swift
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

   let combinedRatio: CGFloat
   if let physicalSizeMM, Self.isValidPhysicalSize(physicalSizeMM) {
       let physicalRatio = min(
           physicalSizeMM.width / Self.referencePhysicalSizeMM.width,
           physicalSizeMM.height / Self.referencePhysicalSizeMM.height
       )
       let w = Self.physicalRatioWeight
       combinedRatio = CGFloat(pow(Double(physicalRatio), Double(w)) * pow(Double(logicalRatio), Double(1.0 - w)))
   } else {
       combinedRatio = logicalRatio
   }
   ```
   Using `min(widthRatio, heightRatio)` on **both** logical and physical dimensions guarantees ultrawide monitors (e.g., 34" `3440 × 1440`, `797 × 334 mm`) are governed by height (`334 / 179 = 1.866`, matching a 27" monitor) and portrait monitors (`1440 × 2560`, `336 × 597 mm`) are governed by width (`336 / 286 = 1.175`, `1440 / 1440 = 1.000`).
4. **Logarithmic scaling curve, quantization & clamping**:
   Quantizing to `0.01` prevents floating-point jitter and eliminates unnecessary view rebuilds:
   ```swift
   let logRatio = CGFloat(log(Double(combinedRatio)))
   let rawSizeScale = 1.0 + Self.sizeCurveGain * logRatio
   let rawFontScale = 1.0 + Self.fontCurveGain * logRatio

   func quantize(_ value: CGFloat) -> CGFloat {
       (value * 100).rounded() / 100
   }
   let sizeScale = quantize(min(max(rawSizeScale, Self.minSizeScale), Self.maxSizeScale))
   let fontScale = quantize(min(max(rawFontScale, Self.minFontScale), Self.maxFontScale))
   ```

### 2.4 AppKit / CoreGraphics Screen Extraction (`DisplayScaleMetrics.from(screen:)`)

```swift
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
```

### 2.5 Reference Table Across Common macOS Displays

| Display Profile (Logical / Physical mm) | `combinedRatio` | `sizeScale` | `fontScale` | Panel Width (`340pt`) | Popover Height (`560pt`*) | Body Font (`12pt`) | Heading (`17pt`) |
|---|---|---|---|---|---|---|---|
| Tiny (`800 × 600`, no EDID) | `0.556` | `0.85` | `0.88` | `289pt` | `476pt` (≤ `85% visH`) | `10.5pt` | `15.0pt` |
| Small (`1024 × 768`, no EDID) | `0.711` | `0.85` | `0.88` | `289pt` | `476pt` | `10.5pt` | `15.0pt` |
| 13" Air (`1280 × 800`, `286 × 179`) | `0.954` | `0.95` | `0.95` | `323pt` | `532pt` | `11.5pt` | `16.0pt` |
| **13.3" Baseline (`1440 × 900`, `286 × 179` or `nil`)** | **`1.000`** | **`1.00`** | **`1.00`** | **`340pt`** | **`560pt`** | **`12.0pt`** | **`17.0pt`** |
| 14.2" MBP (`1512 × 982`, `302 × 196`) | `1.054` | `1.06` | `1.05` | `360pt` | `594pt` | `12.5pt` | `18.0pt` |
| **16.2" MBP (`1728 × 1117`, `345 × 223`)** | **`1.204`** | **`1.21`** | **`1.19`** | **`411pt`** | **`678pt`** | **`14.5pt`** | **`20.0pt`** |
| 16.2" MBP (`1728 × 1117`, no EDID) | `1.200` | `1.21` | `1.18` | `411pt` | `678pt` | `14.0pt` | `20.0pt` |
| **27" 4K HiDPI (`1920 × 1080`, `597 × 336`)** | **`1.570`** | **`1.52`** | **`1.45`** | **`517pt`** | **`851pt`** (≤ `85% visH`) | **`17.5pt`** | **`24.5pt`** |
| **27" QHD/5K (`2560 × 1440`, `597 × 336`)** | **`1.761`** | **`1.60`** | **`1.50`** | **`544pt`** | **`896pt`** | **`18.0pt`** | **`25.5pt`** |
| **27" 4K Native (`3840 × 2160`, `597 × 336`)** | **`2.071`** | **`1.60`** | **`1.50`** | **`544pt`** | **`896pt`** | **`18.0pt`** | **`25.5pt`** |
| 27" QHD (`2560 × 1440`, no EDID) | `1.600` | `1.54` | `1.47` | `524pt` | `862pt` | `17.5pt` | `25.0pt` |
| 32" 4K HiDPI (`1920 × 1080`, `708 × 398`) | `1.737` | `1.60` | `1.50` | `544pt` | `867pt` (clamped on `1020 visH`) | `18.0pt` | `25.5pt` |
| 32" 4K/6K (`3008 × 1692` / `6016 × 3384`, `708 × 398`) | `2.079+` | `1.60` | `1.50` | `544pt` | `896pt` | `18.0pt` | `25.5pt` |
| 34" Ultrawide (`3440 × 1440`, `797 × 334`) | `1.755` | `1.60` | `1.50` | `544pt` | `896pt` | `18.0pt` | `25.5pt` |
| 27" Portrait (`1440 × 2560`, `336 × 597`) | `1.101` | `1.11` | `1.10` | `377pt` | `622pt` | `13.0pt` | `18.5pt` |
| Portrait (`1080 × 1920`, no EDID) | `0.750` | `0.85` | `0.88` | `289pt` | `476pt` | `10.5pt` | `15.0pt` |

*\*All surface heights/widths are additionally clamped to `floor(visibleSize.width * 0.90)` and `floor(visibleSize.height * 0.85)` when `visibleSize` is provided.*

### 2.6 Helper Methods on `DisplayScaleMetrics`

- `public func scaledDimension(_ base: CGFloat, minimum: CGFloat = 0) -> CGFloat`:
  `max(minimum, (base * sizeScale).rounded())` — integer points for container widths/heights/frames.
- `public func scaledSpacing(_ base: CGFloat, minimum: CGFloat = 0) -> CGFloat`:
  `max(minimum, ((base * sizeScale) * 2).rounded() / 2)` — half-point precision for crisp Retina paddings, spacing, radii, and bar heights.
- `public func scaledFontSize(_ base: CGFloat, minimum: CGFloat = DisplayScaleMetrics.minimumFontSize) -> CGFloat`:
  `max(minimum, ((base * fontScale) * 2).rounded() / 2)` — half-point precision matching the codebase's existing `9.5`, `10.5`, `11.5`, `12.5` typography.
- `public func font(_ baseSize: CGFloat, weight: Font.Weight = .regular) -> Font`:
  `.system(size: scaledFontSize(baseSize), weight: weight)`.
- `public func clampedSize(base: CGSize) -> CGSize`:
  Scales `base.width` and `base.height` by `sizeScale` (rounded to integer points), then if `visibleSize` is present and valid (`width > 0 && height > 0`), clamps:
  ```swift
  let maxW = floor(visibleSize.width * Self.maxVisibleWidthRatio)
  let maxH = floor(visibleSize.height * Self.maxVisibleHeightRatio)
  return CGSize(width: min(scaledW, maxW), height: min(scaledH, maxH))
  ```
- Convenience computed properties:
  - `panelWidth: CGFloat` (clamped against `visibleSize.width * 0.90` if `visibleSize` is set)
  - `popoverSize: CGSize` (`clampedSize(base: Self.basePopoverSize)`)
  - `developmentPanelSize: CGSize` (`clampedSize(base: Self.baseDevelopmentPanelSize)`)
  - `settingsWindowSize: CGSize` (`clampedSize(base: Self.baseSettingsWindowSize)`)
  - `settingsContentSize: CGSize` (`clampedSize(base: Self.baseSettingsContentSize)`)
  - `aboutWindowSize: CGSize` (`clampedSize(base: Self.baseAboutWindowSize)`)

---

## 3. View-by-View Integration Plan

### 3.1 `app/Sources/UsageLensUI/DisplayScaling.swift`
- Implement `DisplayScaleMetrics` with the physical + logical formula, EDID validation helper `isValidPhysicalSize(_:)`, `make(displaySize:visibleSize:physicalSizeMM:)`, and `from(screen:)` using `CGDisplayScreenSize`.
- Provide `DisplayScaleController` (`@MainActor ObservableObject`), `DisplayScaleMetricsKey` (`EnvironmentKey`), `EnvironmentValues.displayScaleMetrics`, and `ScaledHostingView<Content: View>` to inject `controller.metrics` into `NSHostingController` roots.

### 3.2 `app/Sources/UsageLensUI/Theme.swift`
- Keep `Theme.panelWidth` (`340`), `Theme.cardCorner` (`10`), `Theme.barHeight` (`6`) as base constants.
- Update `CardBackground` to read `@Environment(\.displayScaleMetrics) private var metrics` and apply `metrics.scaledSpacing(corner)` to `RoundedRectangle(cornerRadius:)`.

### 3.3 `app/Sources/UsageLensUI/PanelView.swift`
- Inject `@Environment(\.displayScaleMetrics) private var metrics` into `PanelView`, `ProviderTabBar`, `ProviderDetailView`, `WindowRowView`, `ProgressTrack`, `MetricTile`, and `FooterBar`.
- Route panel width (`metrics.panelWidth`), all font sizes (`metrics.font(...)`), paddings/spacings/radii (`metrics.scaledSpacing(...)`), `ProgressTrack` height (`metrics.scaledSpacing(Theme.barHeight, minimum: 4)`), and icon button frames (`metrics.scaledDimension(24, minimum: 20)`) through `metrics`.
- Keep `.id("panel-\(selectedTheme.rawValue)-\(themeSignal.revision)")` intact for theme refresh.

### 3.4 `app/Sources/UsageLensUI/SettingsPanelView.swift`
- Read `@Environment(\.displayScaleMetrics) private var metrics`.
- Replace hardcoded `.frame(width: 340, height: 480, alignment: .topLeading)` with `.frame(width: metrics.settingsContentSize.width, height: metrics.settingsContentSize.height, alignment: .topLeading)`.
- Scale paddings, spacings, theme accent circle, card corner radii, and all font sizes (`17`, `13`, `11`, `10`, `9`).

### 3.5 `app/Sources/UsageLensUI/AboutPanelView.swift`
- Read `@Environment(\.displayScaleMetrics) private var metrics`.
- Replace hardcoded `.frame(width: 280, height: 230)` with `.frame(width: metrics.aboutWindowSize.width, height: metrics.aboutWindowSize.height)`.
- Scale spacings, eye icon `.frame(width: metrics.scaledDimension(64), height: metrics.scaledDimension(54))`, and all font sizes (`17`, `15`, `11.5`, `10.5`).

### 3.6 `app/Sources/UsageLens/UsageLensApp.swift`
- Track per-surface `DisplayScaleController` instances (`popover`, `developmentPanel`, `settingsPanel`, `aboutPanel`) and clean up screen observers in `applicationWillTerminate`.
- Resolve `activeStatusScreen()` via `statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first`.
- Update popover metrics + `popover.contentSize` on `togglePopover(_:)` before `popover.show(...)`.
- Size Settings, About, and Development windows on creation/re-open and dynamically update via `NSApplication.didChangeScreenParametersNotification` and `NSWindow.didChangeScreenNotification` using `resizeWindowPreservingCenter(_:to:)` (only when size changes by `>= 1pt` to avoid resize loops).

---

## 4. Edge Cases & Mitigations

| Edge Case | Handling |
|---|---|
| Headless CI / unit tests (`NSScreen.main == nil`) | `DisplayScaleMetrics.from(screen: nil)` returns `.standard` (`1.0 / 1.0`). |
| Zero, negative, `NaN`, or `Infinity` logical display size | `DisplayScaleMetrics.make(...)` validates `isFinite && > 0` and falls back to `.standard`. |
| Missing, zero, or bogus EDID (`CGDisplayScreenSize` returns `0×0`, `16×9 mm`, `5000×3000 mm`, `NaN`) | `isValidPhysicalSize` rejects `< 100 mm`, `> 3000 mm`, or non-finite values and falls back cleanly to logical-only scaling. |
| 27" 4K monitor at macOS default `1920 × 1080` HiDPI | Physical ratio (`336/179 = 1.877`) lifts `sizeScale` to `1.52`, `fontScale` to `1.45` (`517pt` width), while `visibleFrame` clamping caps height at `<= 85%` of `visibleSize.height`. |
| 16.2" MacBook Pro (`1728 × 1117`, `345 × 223 mm`) | Delivers `sizeScale = 1.21`, `fontScale = 1.19` (`411pt` width, `14.5pt` body font). |
| Very small display (`800 × 600`) | `sizeScale` clamps to `0.85`, `fontScale` clamps to `0.88`, fonts floor at `8.5pt`, and `clampedSize` caps window/popover at `90% × 85%` of `visibleFrame`. |
| 34" Ultrawide (`3440 × 1440`, `797 × 334 mm`) | Minimum-axis normalization on both logical and physical ratios matches 27" QHD (`1.60 / 1.50`), preventing horizontal bloat. |
| Portrait (`1440 × 2560` on 27" or `1080 × 1920`) | Minimum-axis normalization uses the narrower horizontal axis (`1.11 / 1.10` or `0.85 / 0.88`), preventing horizontal overflow. |
| 32" 4K / 6K (`3008 × 1692`, `6016 × 3384`, `708 × 398 mm`) | `sizeScale` caps at `1.60`, `fontScale` caps at `1.50`. |
| Multi-monitor drag / display switch | `NSWindow.didChangeScreenNotification` + `NSApplication.didChangeScreenParametersNotification` update only when metrics/size actually change (`>= 1pt` / quantized `0.01`). |

---

## 5. Testing & Verification Strategy

1. **Pure Unit Tests (`app/Tests/UsageLensUITests/DisplayScalingTests.swift`)**:
   - **Baseline**: `1440 × 900` with `286 × 179 mm` and with `physicalSizeMM: nil` both yield `sizeScale == 1.0`, `fontScale == 1.0`, exact base sizes (`340 × 560`, `360 × 520`, `280 × 230`).
   - **Compact 13"–14" displays**: `800 × 600`, `1024 × 768`, `1280 × 800` (`286 × 179 mm`), and `1512 × 982` (`302 × 196 mm`) verify monotonic scaling, `0.85 / 0.88` lower clamps, and balanced 14" sizing (`1.06 / 1.05`).
   - **16" MacBook Pro**: `1728 × 1117` with `345 × 223 mm` yields `sizeScale == 1.21` (`in 1.20...1.25`), `fontScale == 1.19` (`in 1.18...1.22`), `panelWidth == 411` (`in 410...425`); also verify `physicalSizeMM: nil` fallback yields `sizeScale == 1.21`, `fontScale == 1.18`.
   - **27" External Monitors**:
     - 27" 4K HiDPI (`1920 × 1080`, `597 × 336 mm`, `visibleSize: 1920 × 1020`): `sizeScale == 1.52`, `fontScale == 1.45`, `popoverSize.width == 517`, `popoverSize.height <= floor(1020 * 0.85)`.
     - 27" QHD/5K (`2560 × 1440`, `597 × 336 mm`): `sizeScale == 1.60`, `fontScale == 1.50`, `popoverSize.width == 544`.
     - 27" 4K Native (`3840 × 2160`, `597 × 336 mm`): `sizeScale == 1.60`, `fontScale == 1.50`, `popoverSize.width == 544`.
   - **32" 4K/6K Upper Clamps**: `3008 × 1692` and `6016 × 3384` (`708 × 398 mm`) clamp at `maxSizeScale == 1.60`, `maxFontScale == 1.50`.
   - **EDID Fallback**: `physicalSizeMM` of `nil`, `.zero`, negative, `.nan`, `.infinity`, too-small (`16 × 9 mm`), and too-large (`5000 × 3000 mm`) all produce identical output to `physicalSizeMM: nil`.
   - **Aspect-Ratio Safety**: 34" ultrawide (`3440 × 1440`, `797 × 334 mm`) matches 27" QHD (`1.60 / 1.50`); 27" portrait (`1440 × 2560`, `336 × 597 mm`) yields `1.11 / 1.10`; narrow portrait (`1080 × 1920`, `nil`) clamps to `0.85 / 0.88`.
   - **Font Floor & Visible-Frame Clamping**: `scaledFontSize(9.0)` never drops below `8.5pt`; tight `visibleSize` (e.g., `1920 × 900` on 27" 1080p with tall Dock, or `800 × 500`) clamps `popoverSize.height <= floor(visibleSize.height * 0.85)` and `popoverSize.width <= floor(visibleSize.width * 0.90)`.
   - **Invalid/Headless Inputs**: `from(screen: nil)`, `.zero`, negative, `.nan`, `.infinity` logical sizes safely return `.standard`.
2. **Offscreen Render Verification (`app/Tests/UsageLensUITests/DisplayScalingTests.swift`)**:
   - Render `PanelView`, `SettingsPanelView`, and `AboutPanelView` with `ImageRenderer` across compact (`1024 × 768`), baseline (`1440 × 900`), 16" MBP (`1728 × 1117`, `345 × 223 mm`), and 27" monitor (`1920 × 1080`, `597 × 336 mm`) `DisplayScaleMetrics`.
   - Assert rendered `CGImage` dimensions satisfy `compact < baseline < mbp16 < monitor27`.
3. **Existing Test Suite**:
   - Run `cd app && swift build && swift test` and confirm all `UsageLensKitTests` and `UsageLensUITests` pass with zero regressions.
   - Run `python3 -m unittest discover -s tests` to ensure no unintended impact on probes.
