# Specification: Display-Aware Size and Font Scaling

## Overview

`UsageLens` MUST automatically scale its UI surface dimensions (popover, panel, Settings window, About window, Development panel) and typography (fonts, SF Symbols, and proportional layout spacing/radii) based on the active macOS display's logical size, while enforcing readability bounds and usable-area constraints.

---

## Requirements & Acceptance Scenarios

### Requirement 1: Standard Baseline Display (Zero Regression)

On a standard reference display (`1440 × 900` logical points), scaling MUST resolve to `1.0`, preserving existing dimensions and font sizes.

- **Given** an active display with logical size `1440 × 900` (and sufficient visible frame),
- **When** `DisplayScaleMetrics` is computed for that display,
- **Then** `sizeScale` MUST equal `1.0` and `fontScale` MUST equal `1.0`.
- **And** the main panel width MUST be `340pt`, popover height `560pt`, Settings content size `360 × 520pt` (inner view width matching window), and About content size `280 × 230pt`.
- **And** base typography (e.g., `12pt` window row title, `14pt` metric value, `17pt` Settings/About heading) MUST remain unchanged.

### Requirement 2: Compact / Small Display Scaling & Readability Floor

On displays smaller than the reference baseline, UI dimensions and fonts MUST scale down smoothly while respecting lower bounds so content remains legible and fits within the visible screen area.

- **Given** a compact display such as `1280 × 800` or `1024 × 768` logical points,
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` MUST be strictly less than `1.0` and clamped to at least `0.85`.
- **And** `fontScale` MUST be strictly less than `1.0` and clamped to at least `0.88`.
- **And** any scaled font size computed via `scaledFontSize(_:)` MUST never drop below `8.5pt` regardless of the base font size.
- **And** any scaled popover or window size MUST be clamped to at most `90%` of `visibleFrame.width` and `85%` of `visibleFrame.height` so it is never clipped by the menu bar or Dock.

### Requirement 3: Large Display Scaling & Upper Bound

On large displays (e.g., 27" `2560 × 1440` QHD/5K or 32" `3840 × 2160` 4K), UI dimensions and fonts MUST scale up monotonically and smoothly, capped at reasonable upper bounds so the menu bar popover remains crisp and proportional.

- **Given** a large external display such as `2560 × 1440` logical points,
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` and `fontScale` MUST both be strictly greater than `1.0` (e.g., `~1.26`–`1.27` for `2560 × 1440`).
- **And** on very large displays (e.g., `3840 × 2160` or `6016 × 3384`), `sizeScale` MUST be clamped to at most `1.35` and `fontScale` MUST be clamped to at most `1.30`.
- **And** rendered `PanelView` dimensions on a large display configuration MUST be strictly larger than on the standard baseline, which MUST be strictly larger than on a small display configuration.

### Requirement 4: Aspect-Ratio Safety (Ultrawide & Portrait Displays)

Display scaling MUST NOT over-scale on ultrawide monitors or overflow narrow portrait monitors.

- **Given** an ultrawide display (e.g., `3440 × 1440` or `5120 × 1440`),
- **When** `DisplayScaleMetrics` is computed using the minimum axis ratio `min(width / 1440, height / 900)`,
- **Then** the resulting `sizeScale` and `fontScale` MUST match a standard `2560 × 1440` display (governed by height `1440 / 900 = 1.60`) rather than inflating based on the wide horizontal dimension.
- **Given** a portrait display (e.g., `1440 × 2560` or `1080 × 1920`),
- **When** `DisplayScaleMetrics` is computed,
- **Then** scaling MUST be governed by the narrower horizontal axis (`width / 1440`) so panels do not overflow horizontally.

### Requirement 5: Comprehensive Surface & Typography Coverage

All primary UI surfaces MUST respond to `DisplayScaleMetrics`:

- **Main Popover & `PanelView`**: Panel width, popover content size, tab bar (status dots, labels, pill padding, corner radius), detail header (account label, plan badge), stale/warning banners, empty state tile, `WindowRowView` (titles, percentages, countdown/basis, card padding, corner radius, `ProgressTrack` height), `MetricTile` (title, value, note, padding, corner radius), and `FooterBar` (refresh pill, updated timestamp, icon button sizes).
- **Settings Window & `SettingsPanelView`**: Window content size, inner layout width/height/padding/spacing, headings, theme cards (accent dot, title, subtitle, padding, corner radius), toggle/caption text, provider rows, API key input/status text.
- **About Window & `AboutPanelView`**: Window content size, spacing, heading, enlarged eye icon frame, app name, version, and subtitle text.
- **Development Panel (`USAGE_LENS_SHOW_PANEL=1`)**: Panel content size and embedded `PanelView` metrics.
- **Exclusion**: The macOS menu bar status item (`NSStatusItem` length `32` and `MenuBarIcon` `24 × 20`) MUST remain at standard macOS menu bar dimensions.

### Requirement 6: Dynamic Display Changes & Multi-Monitor Switching

UI surfaces MUST update their dimensions and font scaling dynamically without requiring an app restart.

- **Given** a multi-monitor setup (e.g., a 14" laptop screen and a 27" external monitor),
- **When** the user clicks the menu bar icon on the 27" monitor,
- **Then** the popover MUST resolve the screen owning the clicked `NSStatusBarButton` (`button.window?.screen`), update `popover.contentSize`, and render `PanelView` with that screen's `DisplayScaleMetrics`.
- **When** the user later clicks the menu bar icon on the laptop screen,
- **Then** the popover MUST resize and re-render using the laptop screen's `DisplayScaleMetrics`.
- **Given** an open Settings, About, or Development window,
- **When** the user drags the window to another monitor (`NSWindow.didChangeScreenNotification`) OR changes display resolution / connects / disconnects a monitor (`NSApplication.didChangeScreenParametersNotification`),
- **Then** the window MUST update its `DisplayScaleMetrics` and content size to match the new screen without triggering resize loops or losing window visibility.

### Requirement 7: Headless Fallback, Persistence & Compatibility

- **Given** a headless or test environment where `NSScreen` is unavailable (`nil`) or reports zero/non-finite dimensions,
- **When** `DisplayScaleMetrics` is resolved,
- **Then** it MUST safely fall back to `.standard` (`sizeScale = 1.0`, `fontScale = 1.0`) without crashing or producing `NaN`/`Infinity`.
- **Given** existing user preferences (`usageLens.theme`, `usageLens.providers`, Keychain DeepSeek API Key, Launch at Login),
- **When** theme switching or provider list changes occur,
- **Then** existing theme refresh (`ThemeChangeSignal` / `ThemeHostRegistrar`) and settings persistence MUST continue to work identically while preserving the active display's `DisplayScaleMetrics`.
- **Given** existing call sites such as `PanelView(store: store)`, `SettingsPanelView(launchAtLogin:)`, and `AboutPanelView()`,
- **Then** all existing public initializers MUST remain source-compatible (defaulting to `.standard` via SwiftUI `@Environment(\.displayScaleMetrics)`).
