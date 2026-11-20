# Proposal: Auto-Scale Display Size and Font

## Problem Statement

`UsageLens` is a macOS 14+ SwiftUI/AppKit menu bar application whose UI surfaces currently use hardcoded logical point dimensions and hardcoded font sizes:

- **Main Popover & Panel**: `NSPopover.contentSize` is fixed at `340 × 560` (`app/Sources/UsageLens/UsageLensApp.swift`), `Theme.panelWidth` is fixed at `340` (`app/Sources/UsageLensUI/Theme.swift`), and `PanelView` hardcodes font sizes between `9pt` and `14pt` along with fixed paddings, corner radii, and progress bar height (`app/Sources/UsageLensUI/PanelView.swift`).
- **Settings Window**: `settingsPanel` is fixed at `360 × 520` in `UsageLensApp.swift` and `340 × 480` in `SettingsPanelView.swift`, with hardcoded fonts (`9pt`–`17pt`).
- **About Window**: `aboutPanel` is fixed at `280 × 230` in `UsageLensApp.swift` and `AboutPanelView.swift`, with hardcoded fonts (`10.5pt`–`17pt`) and icon size (`64 × 54`).
- **Development Panel**: `developmentPanel` (`USAGE_LENS_SHOW_PANEL=1`) is fixed at `368 × 620`.

On large external monitors (e.g., 27" QHD/5K at `2560 × 1440` logical points, 4K "More Space" at `3008 × 1692`, or native 4K/6K displays), a `340pt` panel with `9pt`–`12pt` text appears overly small and hard to read. Conversely, on compact displays (e.g., `1024 × 768` or `1280 × 720` logical points, projectors, or small laptops), a `560pt`-tall popover or `520pt`-tall settings window can feel cramped or risk clipping against the Dock and menu bar.

## User Requirement

> 能够根据显示屏的大小自动缩放显示size的大小和字体大小。

## Goals

1. **Automatic display-aware scaling**: Compute deterministic size and font scale factors from the active display's logical dimensions (`NSScreen.frame.size`) with safe clamping to the usable area (`NSScreen.visibleFrame.size`).
2. **Coordinated UI scaling**: Proportionally scale container dimensions (popover, panel, settings window, about window, development panel), typography (all text & SF Symbol sizes), and supporting layout metrics (paddings, spacing, corner radii, progress bar height, icon frames) across `UsageLensUI` and `UsageLens`.
3. **Readable bounds & aspect-ratio safety**: Apply damped scaling with explicit min/max bounds and a minimum font-size floor so text stays legible on small screens and surfaces never become oversized on 4K/5K/6K or ultrawide/portrait displays.
4. **Dynamic display adaptation**: Automatically recalculate and apply scaling when:
   - Opening the popover on a different monitor in a multi-display setup.
   - Moving an open Settings, About, or Development window between displays (`NSWindow.didChangeScreenNotification`).
   - Reconfiguring displays or changing display resolution/scaling in macOS System Settings (`NSApplication.didChangeScreenParametersNotification`).
5. **Deterministic testability & zero regressions**: Encapsulate scaling math in a pure, side-effect-free value type (`DisplayScaleMetrics`) so unit tests and `ImageRenderer` snapshot tests verify math, clamping, and rendered sizes deterministically without flaky GUI or `NSScreen` dependencies.

## Non-Goals

- **Menu bar status item icon (`NSStatusItem` / `MenuBarIcon`)**: The macOS menu bar height is system-managed and already scales with macOS display resolution; resizing the `24 × 20` eye icon or `32pt` status item length would break visual alignment with native macOS menu bar icons.
- **Manual user zoom slider / override UI**: The requirement asks for automatic scaling based on display size; adding manual scale controls or new persistent preference UI is out of scope for this change.
- **Third-party dependencies**: Per `app/Package.swift`, the app strictly uses SwiftUI, AppKit, and Foundation only.
- **Probe / data-layer changes**: `probes/` and `UsageLensKit` probe parsing/formatting contracts are untouched.

## User Impact & Scope

- **Standard MacBook baseline (`1440 × 900` logical points)**: Scale factor is `1.00`, preserving the exact existing visual appearance and layout with zero visual regression.
- **Compact displays (`< 1440 × 900`)**: Panels, windows, and fonts smoothly scale down within safe readability bounds and never exceed the screen's `visibleFrame`.
- **Large displays (`> 1440 × 900`, e.g., 27" QHD/5K, 32" 4K/6K)**: Panels, windows, and fonts scale up smoothly (up to capped maxima) for comfortable readability without becoming oversized.
- **Affected modules**:
  - `app/Sources/UsageLensUI/` (new `DisplayScaling.swift`, updates to `Theme.swift`, `PanelView.swift`, `SettingsPanelView.swift`, `AboutPanelView.swift`)
  - `app/Sources/UsageLens/UsageLensApp.swift` (screen detection, dynamic resize, environment propagation)
  - `app/Tests/UsageLensUITests/` (unit tests for `DisplayScaleMetrics` math/bounds/clamping + offscreen render size verification)
