# Technical Design: Auto-Scale Display Size and Font

## 1. Architecture Overview

The feature is structured into three cleanly separated layers, adhering strictly to the zero-third-party-dependency constraint (`SwiftUI`, `AppKit`, `Foundation` only):

1. **Pure Scaling Model (`UsageLensUI/DisplayScaling.swift`)**:
   - `DisplayScaleMetrics`: An immutable `Equatable, Sendable` value type that computes `sizeScale`, `fontScale`, scaled dimensions, scaled font sizes, and clamped window/popover sizes from raw `CGSize` inputs. Contains zero `NSScreen` side effects in its core math so unit tests are 100% deterministic.
   - `DisplayScaleMetrics.from(screen: NSScreen?)`: Thin AppKit adapter reading `screen.frame.size` and `screen.visibleFrame.size` with `.standard` fallback when `screen == nil`.
   - `DisplayScaleController` (`@MainActor ObservableObject`): Holds `@Published public var metrics: DisplayScaleMetrics` per window/surface (or shared/scoped instances) so dynamic screen changes trigger immediate SwiftUI updates.
   - SwiftUI `@Environment(\.displayScaleMetrics)`: Propagates `DisplayScaleMetrics` down the view tree without breaking any existing `init` signatures.

2. **Scaled SwiftUI Views (`UsageLensUI`)**:
   - `Theme.swift`: Keep existing base constants (`Theme.panelWidth = 340`, `Theme.cardCorner = 10`, `Theme.barHeight = 6`) as the `1.0x` reference values; update `CardBackground` to scale its corner radius via `@Environment(\.displayScaleMetrics)`.
   - `PanelView.swift`, `SettingsPanelView.swift`, `AboutPanelView.swift`: Read `@Environment(\.displayScaleMetrics) private var metrics` and route all container frames, font sizes, paddings, spacings, icon frames, and corner radii through `metrics.scaled(_:)` / `metrics.font(_:weight:)`.

3. **AppKit Window & Display Observer (`UsageLens/UsageLensApp.swift`)**:
   - Track active `DisplayScaleController` instances for `popover`, `developmentPanel`, `settingsPanel`, and `aboutPanel`.
   - On `togglePopover(_:)`, resolve `let screen = button.window?.screen ?? NSScreen.main ?? NSScreen.screens.first`, update popover controller metrics + `popover.contentSize` before `popover.show(...)`.
   - Subscribe to `NSApplication.didChangeScreenParametersNotification` and `NSWindow.didChangeScreenNotification` (for Settings, About, Development panels) to recompute `DisplayScaleMetrics` and resize open windows smoothly.

---

## 2. Scaling Formula & Clamping Bounds

### 2.1 Reference Constants

```swift
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
}
```

### 2.2 Exact Calculation (`DisplayScaleMetrics.make(displaySize:visibleSize:)`)

1. **Input validation (headless/invalid guard)**:
   - If `!displaySize.width.isFinite || !displaySize.height.isFinite || displaySize.width <= 0 || displaySize.height <= 0`, return `.standard` (`sizeScale = 1.0`, `fontScale = 1.0`, `visibleSize = nil`).
2. **Axis-safe raw ratio**:
   ```swift
   let widthRatio = displaySize.width / Self.referenceDisplaySize.width
   let heightRatio = displaySize.height / Self.referenceDisplaySize.height
   let rawRatio = min(widthRatio, heightRatio)
   ```
   Using `min(widthRatio, heightRatio)` prevents ultrawide displays (e.g., `3440 × 1440`) from over-scaling and prevents portrait displays (e.g., `1080 × 1920`) from overflowing horizontally.
3. **Sublinear damping (square-root curve)**:
   ```swift
   let damped = sqrt(rawRatio)
   ```
   `sqrt(rawRatio)` is strictly monotonic, smooth across all resolutions, equals `1.0` at the `1440 × 900` baseline, and grows gently on high-logical-resolution external monitors so a menu bar popover remains compact and refined.
4. **Quantization & clamping**:
   Quantizing to `0.01` prevents floating-point jitter and eliminates unnecessary view rebuilds on negligible sub-pixel changes:
   ```swift
   func quantize(_ value: CGFloat) -> CGFloat {
       (value * 100).rounded() / 100
   }
   let sizeScale = quantize(min(max(damped, Self.minSizeScale), Self.maxSizeScale))
   let fontScale = quantize(min(max(damped, Self.minFontScale), Self.maxFontScale))
   ```

### 2.3 Reference Table Across Common macOS Displays

| Display Profile (Logical Points) | `rawRatio` | `sqrt(rawRatio)` | `sizeScale` | `fontScale` | Panel Width (`340pt`) | Popover Height (`560pt`) | Body Font (`12pt`) | Heading (`17pt`) |
|---|---|---|---|---|---|---|---|---|
| Tiny (`800 × 600`) | `0.556` | `0.745` | `0.85` | `0.88` | `289pt` | `476pt` (clamped ≤ `510pt`) | `10.5pt` | `15.0pt` |
| Small (`1024 × 768`) | `0.711` | `0.843` | `0.85` | `0.88` | `289pt` | `476pt` | `10.5pt` | `15.0pt` |
| 13" Air (`1280 × 800`) | `0.889` | `0.943` | `0.94` | `0.94` | `320pt` | `526pt` | `11.5pt` | `16.0pt` |
| **Baseline (`1440 × 900`)** | **`1.000`** | **`1.000`** | **`1.00`** | **`1.00`** | **`340pt`** | **`560pt`** | **`12.0pt`** | **`17.0pt`** |
| 14" MBP (`1512 × 982`) | `1.050` | `1.025` | `1.02` | `1.02` | `347pt` | `571pt` | `12.0pt` | `17.5pt` |
| 16" MBP (`1728 × 1117`) | `1.200` | `1.095` | `1.10` | `1.10` | `374pt` | `616pt` | `13.0pt` | `18.5pt` |
| 27" QHD/5K (`2560 × 1440`) | `1.600` | `1.265` | `1.26` | `1.26` | `428pt` | `706pt` | `15.0pt` | `21.5pt` |
| Ultrawide (`3440 × 1440`) | `1.600` | `1.265` | `1.26` | `1.26` | `428pt` | `706pt` | `15.0pt` | `21.5pt` |
| 4K Native (`3840 × 2160`) | `2.400` | `1.549` | `1.35` | `1.30` | `459pt` | `756pt` | `15.5pt` | `22.0pt` |

### 2.4 Helper Methods on `DisplayScaleMetrics`

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

### 3.1 `app/Sources/UsageLensUI/DisplayScaling.swift` (New File)
- Define `DisplayScaleMetrics`, `DisplayScaleController` (`@MainActor ObservableObject`), `DisplayScaleMetricsKey` (`EnvironmentKey`), and `EnvironmentValues.displayScaleMetrics`.
- Provide a small `ScaledHostingContainer<Content: View>: View` (or `@ObservedObject` wrapper) so `NSHostingController` roots automatically inject `.environment(\.displayScaleMetrics, controller.metrics)` whenever `controller.metrics` updates.

### 3.2 `app/Sources/UsageLensUI/Theme.swift`
- Keep `Theme.panelWidth` (`340`), `Theme.cardCorner` (`10`), `Theme.barHeight` (`6`) as base constants.
- Update `CardBackground` to read `@Environment(\.displayScaleMetrics) private var metrics` and apply `metrics.scaledSpacing(corner)` to `RoundedRectangle(cornerRadius:)`.

### 3.3 `app/Sources/UsageLensUI/PanelView.swift`
- Inject `@Environment(\.displayScaleMetrics) private var metrics` into:
  - `PanelView`: `.frame(width: metrics.panelWidth)`, detail padding `metrics.scaledSpacing(14 / 12 / 14)`.
  - `ProviderTabBar`: dot `metrics.scaledSpacing(6)`, font `metrics.font(12, weight: ...)`, spacing/padding/corner radius scaled via `metrics.scaledSpacing(...)`.
  - `ProviderDetailView`: `VStack(spacing: metrics.scaledSpacing(12))`, all font sizes (`11.5`, `9`, `10`, `10.5`, `11`, `18`, `12.5`) via `metrics.font(...)`, paddings & badge/banner radii scaled.
  - `WindowRowView`: `VStack(spacing: metrics.scaledSpacing(7))`, `HStack(spacing: metrics.scaledSpacing(8 / 6))`, fonts (`12`, `10.5`), paddings (`11`, `10`).
  - `ProgressTrack`: `.frame(height: metrics.scaledSpacing(Theme.barHeight, minimum: 4))`, min pill width `metrics.scaledSpacing(4, minimum: 3)`.
  - `MetricTile`: `VStack(spacing: metrics.scaledSpacing(2))`, fonts (`9.5`, `14`, `9`), `.padding(metrics.scaledSpacing(9))`, `.cardBackground(corner: 9)` (scaled by `CardBackground`).
  - `FooterBar`: `HStack(spacing: metrics.scaledSpacing(10))`, paddings (`12`, `8`), fonts (`10.5`, `10`, `9.5`), icon button frames `metrics.scaledDimension(24, minimum: 20)`, refresh pill padding scaled.
- Note on `.id(...)` in `PanelView`: Keep `.id("panel-\(selectedTheme.rawValue)-\(themeSignal.revision)")` intact for theme refresh; SwiftUI `@Environment(\.displayScaleMetrics)` naturally triggers view updates without needing to tear down state on scale changes.

### 3.4 `app/Sources/UsageLensUI/SettingsPanelView.swift`
- Read `@Environment(\.displayScaleMetrics) private var metrics`.
- Replace hardcoded `.frame(width: 340, height: 480, alignment: .topLeading)` with `.frame(width: metrics.settingsContentSize.width, height: metrics.settingsContentSize.height, alignment: .topLeading)` (or `minWidth` / `idealWidth` matching the scaled window so scrolling still works cleanly on compact screens).
- Scale `VStack(spacing: 16)`, `.padding(20)`, theme accent circle (`13`), theme card padding (`8`) & corner radius (`9`), all font sizes (`17`, `13`, `11`, `10`, `9`), and spacings (`8`, `9`, `5`, `3`, `2`).

### 3.5 `app/Sources/UsageLensUI/AboutPanelView.swift`
- Read `@Environment(\.displayScaleMetrics) private var metrics`.
- Replace hardcoded `.frame(width: 280, height: 230)` with `.frame(width: metrics.aboutWindowSize.width, height: metrics.aboutWindowSize.height)`.
- Scale `VStack(spacing: 14)` and `VStack(spacing: 3)`, eye icon `.frame(width: metrics.scaledDimension(64), height: metrics.scaledDimension(54))`, and all font sizes (`17`, `15`, `11.5`, `10.5`).

### 3.6 `app/Sources/UsageLens/UsageLensApp.swift`
- Add per-surface `DisplayScaleController` instances:
  - `popoverScaleController`
  - `developmentScaleController`
  - `settingsScaleController`
  - `aboutScaleController`
- Add `screenParametersObserver: NSObjectProtocol?` and `windowScreenObservers: [NSObjectProtocol] = []` (cleaned up in `applicationWillTerminate`).
- Screen resolution helper:
  ```swift
  private func activeStatusScreen() -> NSScreen? {
      statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
  }
  ```
- **Popover (`togglePopover(_:)`)**:
  - Before `popover.show(...)`, compute `let metrics = DisplayScaleMetrics.from(screen: activeStatusScreen())`.
  - Update `popoverScaleController.update(metrics)` and `popover.contentSize = metrics.popoverSize`.
  - Keep the existing theme refresh (`popover.appearance`, rebuilding `host.rootView` wrapped with `popoverScaleController`).
- **Settings / About / Development Windows**:
  - On creation: resolve `let screen = activeStatusScreen()`, compute `metrics`, set initial `contentRect` to `metrics.settingsWindowSize` / `metrics.aboutWindowSize` / `metrics.developmentPanelSize`, wrap `rootView` with the window's `DisplayScaleController`, and observe `NSWindow.didChangeScreenNotification` for that window.
  - On re-showing an existing `settingsPanel` or `aboutPanel`: sync `panel.appearance = UsageLensTheme.appkitAppearance`, refresh metrics from `panel.screen ?? activeStatusScreen()`, and resize if needed before `makeKeyAndOrderFront(nil)`.
  - On `NSApplication.didChangeScreenParametersNotification`:
    - If `popover.isShown`, recompute from `activeStatusScreen()`, update `popoverScaleController` and `popover.contentSize`.
    - For each open window (`settingsPanel`, `aboutPanel`, `developmentPanel`), recompute from `window.screen ?? activeStatusScreen()`, update its controller, and call a helper `resizeWindowPreservingCenter(_:to:)` ONLY if `newMetrics != oldMetrics` (or size changed by `>= 1pt`).
- **Resize helper (anti-jump / anti-loop)**:
  ```swift
  private func resizeWindowPreservingCenter(_ window: NSWindow, to contentSize: NSSize) {
      let current = window.contentRect(forFrameRect: window.frame).size
      guard abs(current.width - contentSize.width) >= 1 || abs(current.height - contentSize.height) >= 1 else {
          return
      }
      let oldFrame = window.frame
      let newFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
      let newOrigin = NSPoint(
          x: oldFrame.midX - newFrameSize.width / 2,
          y: oldFrame.midY - newFrameSize.height / 2
      )
      window.setFrame(NSRect(origin: newOrigin, size: newFrameSize), display: true, animate: false)
  }
  ```

---

## 4. Edge Cases & Mitigations

| Edge Case | Handling |
|---|---|
| Headless CI / unit tests (`NSScreen.main == nil`) | `DisplayScaleMetrics.from(screen: nil)` returns `.standard` (`1.0 / 1.0`). |
| Zero, negative, `NaN`, or `Infinity` display size | `DisplayScaleMetrics.make(...)` validates `isFinite && > 0` and falls back to `.standard`. |
| Very small display (`800 × 600`) | `sizeScale` clamps to `0.85`, `fontScale` clamps to `0.88`, fonts floor at `8.5pt`, and `clampedSize` caps window/popover at `90% × 85%` of `visibleFrame`. |
| Ultrawide (`3440 × 1440`, `5120 × 1440`) | `min(widthRatio, heightRatio)` uses height ratio (`1.60`), preventing horizontal bloat. |
| Portrait (`1080 × 1920`, `1440 × 2560`) | `min(widthRatio, heightRatio)` uses width ratio, preventing horizontal overflow. |
| 4K / 5K / 6K (`3840 × 2160`+) | `sizeScale` caps at `1.35`, `fontScale` caps at `1.30`. |
| Multi-monitor drag / display switch | `NSWindow.didChangeScreenNotification` + `NSApplication.didChangeScreenParametersNotification` update only when metrics/size actually change (`>= 1pt` / quantized `0.01`), preventing resize loops. |
| Theme switching while scaled | `PanelView`'s `.id(...)` rebuilds inside `ScaledHostingContainer`, preserving the current `DisplayScaleMetrics` from `DisplayScaleController`. |

---

## 5. Testing & Verification Strategy

1. **Pure Unit Tests (`app/Tests/UsageLensUITests/DisplayScalingTests.swift`)**:
   - Baseline `1440 × 900` yields `sizeScale == 1.0`, `fontScale == 1.0`, exact base sizes (`340 × 560`, `360 × 520`, `280 × 230`).
   - Small displays (`1280 × 800`, `1024 × 768`, `800 × 600`) scale down monotonically and clamp at `minSizeScale` (`0.85`) / `minFontScale` (`0.88`).
   - Font floor test: `scaledFontSize(9.0)` on smallest scale never drops below `8.5pt`.
   - Large displays (`1728 × 1117`, `2560 × 1440`, `3840 × 2160`, `6016 × 3384`) scale up monotonically and clamp at `maxSizeScale` (`1.35`) / `maxFontScale` (`1.30`).
   - Ultrawide (`3440 × 1440`) produces identical scales to `2560 × 1440`.
   - Portrait (`1080 × 1920`) is constrained by width and never overflows.
   - `visibleSize` clamping: on a small `visibleSize` (e.g. `800 × 500`), `popoverSize.height <= floor(500 * 0.85) == 425` and `popoverSize.width <= floor(800 * 0.90) == 720`.
   - Invalid/headless inputs (`nil` screen, `.zero`, negative, `.nan`, `.infinity`) safely return `.standard`.
2. **Offscreen Render Verification (`app/Tests/UsageLensUITests/PanelRenderTests.swift` or `DisplayScalingTests.swift`)**:
   - Render `PanelView`, `SettingsPanelView`, and `AboutPanelView` with `ImageRenderer` under small (`1024 × 768`), standard (`1440 × 900`), and large (`2560 × 1440`) `DisplayScaleMetrics` via `.environment(\.displayScaleMetrics, ...)`.
   - Assert rendered `CGImage` widths and heights satisfy `small < standard < large`, confirming both container dimensions and SwiftUI content actually scale.
3. **Existing Test Suite**:
   - Run `cd app && swift build && swift test` and confirm all `UsageLensKitTests` and `UsageLensUITests` pass with zero regressions.
   - Run `python3 -m unittest discover -s tests` (or `pytest` if installed) to ensure no unintended impact on probes.
