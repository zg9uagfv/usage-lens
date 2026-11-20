# Proposal: Auto-Scale Display Size and Font

## Problem Statement

`UsageLens` is a macOS 14+ SwiftUI/AppKit menu bar application whose UI surfaces originally used hardcoded logical point dimensions and hardcoded font sizes:

- **Main Popover & Panel**: `NSPopover.contentSize` is fixed at `340 × 560` (`app/Sources/UsageLens/UsageLensApp.swift`), `Theme.panelWidth` is fixed at `340` (`app/Sources/UsageLensUI/Theme.swift`), and `PanelView` hardcodes font sizes between `9pt` and `14pt` along with fixed paddings, corner radii, and progress bar height (`app/Sources/UsageLensUI/PanelView.swift`).
- **Settings Window**: `settingsPanel` is fixed at `360 × 520` in `UsageLensApp.swift` and `340 × 480` in `SettingsPanelView.swift`, with hardcoded fonts (`9pt`–`17pt`).
- **About Window**: `aboutPanel` is fixed at `280 × 230` in `UsageLensApp.swift` and `AboutPanelView.swift`, with hardcoded fonts (`10.5pt`–`17pt`) and icon size (`64 × 54`).
- **Development Panel**: `developmentPanel` (`USAGE_LENS_SHOW_PANEL=1`) is fixed at `368 × 620`.

### Round 2 Calibration Bug Report

> "在一个27寸的显示器上，看这个程序就看起来很小，在16寸的macbook上点击看起都觉得有点小。"

The initial Round 1 scaling design relied solely on a square-root-damped ratio of logical `NSScreen.frame.size` against `1440 × 900` (`sqrt(min(w/1440, h/900))`, capped at `1.35x` size / `1.30x` font). In real-world macOS usage, this under-scales severely on both laptops and external desktop monitors:

- **16-inch MacBook Pro (`1728 × 1117` logical, `~16.2"` / `345 × 223 mm`)**: `sqrt(1728 / 1440) = 1.095` → only `1.10x` (`374pt` width, `13.0pt` body font), which still feels small on a 16-inch screen.
- **27-inch 4K monitor at macOS default HiDPI (`1920 × 1080` logical, `~27"` / `597 × 336 mm`)**: Logical-only scaling sees only `1920 × 1080` (`min = 1.20`), yielding only `1.10x` (`374pt` width) — visually tiny on a 27-inch monitor viewed from desktop distance.
- **27-inch QHD/5K monitor (`2560 × 1440` logical, `~27"` / `597 × 336 mm`)**: `sqrt(1.60) = 1.265` → only `1.26x` (`428pt` width), still undersized on a 27-inch desktop monitor.

Conversely, compact 13"–14" displays (`1024 × 768`, `1280 × 800`, `1440 × 900`, `1512 × 982`) must remain well-proportioned and never clip against the menu bar or Dock.

## User Requirement

> 能够根据显示屏的大小自动缩放显示size的大小和字体大小。
> Bug 修复：在 27 寸显示器上看起来很小，在 16 寸 MacBook 上点击看起来也偏小，需结合物理屏幕尺寸与逻辑分辨率重新标定缩放曲线与上下限，使 16 寸 MacBook 和 27 寸显示器均有明显舒适的放大效果。

## Goals

1. **Physical + logical display-aware scaling**: Combine physical display dimensions from CoreGraphics (`CGDisplayScreenSize(displayID)` via `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`, with safe EDID validation and fallback) with logical display dimensions (`NSScreen.frame.size`) and usable-area clamping (`NSScreen.visibleFrame.size`).
2. **Comfortable visual sizing across real macOS displays**:
   - **13.3" baseline (`1440 × 900`, `~286 × 179 mm`)**: `1.00x` (`340pt` width) — zero visual regression.
   - **Compact 13"–14" screens**: Well-proportioned (`0.85x–1.06x`), never cramped or clipped.
   - **16-inch MacBook Pro (`1728 × 1117`, `~345 × 223 mm`)**: Noticeably larger (`~1.21x` size, `~1.19x` font, `~411pt` popover width).
   - **27-inch external monitors (`~597 × 336 mm`, whether `1920 × 1080` HiDPI, `2560 × 1440`, or `3840 × 2160`)**: Comfortably larger (`~1.52x–1.60x` size, `~1.45x–1.50x` font, `~517–544pt` popover width), safely clamped to `90% × 85%` of `visibleFrame`.
3. **Coordinated UI scaling**: Proportionally scale container dimensions (popover, panel, settings window, about window, development panel), typography (all text & SF Symbol sizes), and supporting layout metrics (paddings, spacing, corner radii, progress bar height, icon frames) across `UsageLensUI` and `UsageLens`.
4. **Readable bounds & aspect-ratio safety**: Enforce min/max scale bounds (`sizeScale ∈ [0.85, 1.60]`, `fontScale ∈ [0.88, 1.50]`), a `>= 8.5pt` minimum font floor, and minimum-axis normalization on both logical and physical ratios so ultrawide and portrait displays never over-scale or overflow horizontally.
5. **Dynamic display adaptation**: Automatically recalculate and apply scaling when opening the popover on a different monitor, moving an open window across displays (`NSWindow.didChangeScreenNotification`), or changing display resolution/configuration (`NSApplication.didChangeScreenParametersNotification`).
6. **Deterministic testability & zero regressions**: Keep all scaling math in a pure, side-effect-free `DisplayScaleMetrics.make(displaySize:visibleSize:physicalSizeMM:)` API so unit tests and `ImageRenderer` snapshot tests verify math, EDID fallback, clamping, and rendered dimensions deterministically.

## Non-Goals

- **Menu bar status item icon (`NSStatusItem` / `MenuBarIcon`)**: The macOS menu bar height is system-managed; resizing the `24 × 20` eye icon or `32pt` status item length would break alignment with native macOS menu bar icons.
- **Manual user zoom slider / override UI**: The requirement asks for automatic scaling based on display size; adding manual scale preferences is out of scope.
- **Third-party dependencies**: Per `app/Package.swift`, the app strictly uses SwiftUI, AppKit, CoreGraphics, and Foundation only.
- **Probe / data-layer changes**: `probes/` and `UsageLensKit` probe parsing/formatting contracts are untouched.

## User Impact & Scope

- **13.3" Standard MacBook baseline (`1440 × 900`, `286 × 179 mm` or no EDID)**: `1.00x` scale, exact existing appearance.
- **Compact displays (`< 1440 × 900`)**: Smoothly scaled down within safe readability bounds and clamped to `visibleFrame`.
- **16-inch MacBook Pro (`1728 × 1117`, `345 × 223 mm`)**: Noticeably larger (`1.21x` size, `1.19x` font, `411pt` panel width).
- **27-inch & 32-inch external monitors (`597 × 336 mm` / `708 × 398 mm`)**: Comfortably larger (`1.52x–1.60x` size, `1.45x–1.50x` font, `517–544pt` panel width) even when running macOS default `1920 × 1080` HiDPI scaling, while remaining clamped to `90% × 85%` of `visibleFrame`.
- **Affected modules**:
  - `app/Sources/UsageLensUI/` (`DisplayScaling.swift`, `Theme.swift`, `PanelView.swift`, `SettingsPanelView.swift`, `AboutPanelView.swift`)
  - `app/Sources/UsageLens/UsageLensApp.swift` (screen detection, dynamic resize, environment propagation)
  - `app/Tests/UsageLensUITests/` (unit tests for physical + logical scaling math, EDID fallback, bounds/clamping + offscreen render size verification)
