# Specification: Display-Aware Size and Font Scaling

## Overview

`UsageLens` MUST automatically scale its UI surface dimensions (popover, panel, Settings window, About window, Development panel) and typography (fonts, SF Symbols, and proportional layout spacing/radii) using both the active macOS display's physical size (`CGDisplayScreenSize`) and logical size (`NSScreen.frame.size`), while enforcing readability bounds, EDID fallbacks, aspect-ratio safety, and usable-area (`NSScreen.visibleFrame.size`) clamping.

---

## Requirements & Acceptance Scenarios

### Requirement 1: Standard Baseline Display (Zero Regression)

On a standard 13.3" reference display (`1440 × 900` logical points, `286 × 179 mm` physical size or unavailable EDID), scaling MUST resolve to `1.0`, preserving existing dimensions and font sizes.

- **Given** an active display with logical size `1440 × 900` and either `physicalSizeMM == CGSize(width: 286, height: 179)` or `physicalSizeMM == nil`,
- **When** `DisplayScaleMetrics` is computed for that display,
- **Then** `sizeScale` MUST equal `1.0` and `fontScale` MUST equal `1.0`.
- **And** the main panel width MUST be `340pt`, popover height `560pt`, Settings window & `SettingsPanelView` content size `360 × 520pt`, and About window & `AboutPanelView` content size `280 × 230pt`.
- **And** base typography (e.g., `12pt` window row title, `14pt` metric value, `17pt` Settings/About heading) MUST remain unchanged.

### Requirement 2: Compact & 13"–14" Display Scaling & Readability Floor

On displays smaller than the baseline (and compact 13"–14" laptops), UI dimensions and fonts MUST remain well-proportioned, scale down smoothly when below baseline, and respect lower bounds so content stays legible and fits within the visible screen area.

- **Given** a compact display such as `1280 × 800` (with or without `286 × 179 mm` EDID), `1024 × 768`, or `800 × 600` logical points,
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` MUST be strictly less than `1.0` and clamped to at least `0.85`.
- **And** `fontScale` MUST be strictly less than `1.0` and clamped to at least `0.88`.
- **And** any scaled font size computed via `scaledFontSize(_:)` MUST never drop below `8.5pt` regardless of the base font size.
- **And** any scaled popover or window size MUST be clamped to at most `90%` of `visibleFrame.width` and `85%` of `visibleFrame.height` so it is never clipped by the menu bar or Dock.
- **Given** a 14.2" MacBook Pro (`1512 × 982` logical, `302 × 196 mm` physical),
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` MUST be modestly above `1.0` (`~1.05–1.08`, exact `1.06`) and `fontScale` MUST be modestly above `1.0` (`~1.04–1.07`, exact `1.05`), keeping compact 14" layouts balanced.

### Requirement 3: 16-Inch MacBook Pro Scaling

On a 16-inch MacBook Pro (`~16.2"`, `1728 × 1117` logical, `345 × 223 mm` physical), UI surfaces and typography MUST scale noticeably larger than the 13.3" baseline so the popover and text feel comfortable rather than small.

- **Given** a 16.2" MacBook Pro display (`1728 × 1117` logical, `345 × 223 mm` physical),
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` MUST fall in `1.20...1.25` (exact `1.21`), `fontScale` MUST fall in `1.18...1.22` (exact `1.19`), and `panelWidth` / `popoverSize.width` MUST fall in `410...425pt` (exact `411pt`).
- **And** even if EDID is unavailable (`physicalSizeMM == nil`) on `1728 × 1117`, `sizeScale` MUST still fall in `1.20...1.25` (exact `1.21`) and `fontScale` in `1.18...1.22` (exact `1.18`).

### Requirement 4: 27-Inch & Larger External Monitor Scaling & Upper Bound

On 27-inch external desktop monitors (`~27"`, `597 × 336 mm` physical) across common macOS logical scaling modes (`1920 × 1080` HiDPI default, `2560 × 1440` QHD/5K, and `3840 × 2160` native 4K) as well as 32-inch 4K/6K monitors, UI surfaces and fonts MUST scale comfortably larger while respecting upper bounds and `visibleFrame` limits.

- **Given** a 27" 4K monitor running macOS default HiDPI (`1920 × 1080` logical, `597 × 336 mm` physical, e.g., `visibleSize = 1920 × 1020`),
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` MUST fall in `1.45...1.60` (exact `1.52`), `fontScale` MUST fall in `1.38...1.50` (exact `1.45`), and `popoverSize.width` MUST fall in `490...545pt` (exact `517pt`).
- **And** `popoverSize.height` MUST be safely clamped to at most `floor(visibleSize.height * 0.85)`.
- **Given** a 27" QHD/5K monitor (`2560 × 1440` logical, `597 × 336 mm` physical) or 27" native 4K monitor (`3840 × 2160` logical, `597 × 336 mm` physical),
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` MUST fall in `1.45...1.60` (exact `1.60`), `fontScale` MUST fall in `1.38...1.50` (exact `1.50`), and `popoverSize.width` MUST be `544pt` (still clamped to `90% × 85%` of `visibleSize`).
- **Given** very large displays (e.g., 32" 4K/6K `3008 × 1692` or `6016 × 3384`, `708 × 398 mm`),
- **When** `DisplayScaleMetrics` is computed,
- **Then** `sizeScale` MUST be clamped to at most `1.60` and `fontScale` MUST be clamped to at most `1.50`.
- **And** rendered `PanelView` dimensions MUST satisfy strict ordering: `compact (1024 × 768) < baseline (1440 × 900) < 16" MBP (1728 × 1117, 345 × 223 mm) < 27" monitor (1920 × 1080 or 2560 × 1440, 597 × 336 mm)`.

### Requirement 5: Physical EDID Fallback & Validation

Physical screen size detection via `CGDisplayScreenSize(displayID)` MUST degrade gracefully when EDID metadata is missing, zero, non-finite, or implausible.

- **Given** a display whose `physicalSizeMM` is `nil`, `.zero`, negative, non-finite (`.nan`/`.infinity`), or outside plausible display bounds (`< 100 mm` or `> 3000 mm` on either axis),
- **When** `DisplayScaleMetrics.make(displaySize:visibleSize:physicalSizeMM:)` is called,
- **Then** the invalid physical dimensions MUST be ignored and scaling MUST fall back cleanly to the logical-only ratio derived from `displaySize`.
- **And** `DisplayScaleMetrics.from(screen:)` MUST safely extract `CGDirectDisplayID` from `screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]` and fall back to logical-only scaling if the display ID is absent or `CGDisplayScreenSize` returns zero/invalid dimensions.

### Requirement 6: Aspect-Ratio Safety (Ultrawide & Portrait Displays)

Display scaling MUST NOT over-scale on ultrawide monitors or overflow narrow portrait monitors, in both physical and logical dimensions.

- **Given** a 34" ultrawide display (`3440 × 1440` logical, `797 × 334 mm` physical),
- **When** `DisplayScaleMetrics` is computed using minimum-axis ratios for both logical (`min(w/1440, h/900)`) and physical (`min(mmW/286, mmH/179)`) dimensions,
- **Then** scaling MUST be governed by the vertical axis (matching a 27" `2560 × 1440` monitor's `~336 mm` physical height) rather than inflating based on the wide horizontal dimension.
- **Given** a portrait display (e.g., 27" rotated `1440 × 2560` with `336 × 597 mm`, or `1080 × 1920` without EDID),
- **When** `DisplayScaleMetrics` is computed,
- **Then** scaling MUST be governed by the narrower horizontal axis so panels remain modest (`1.11x` for `1440 × 2560`, `0.85x` for `1080 × 1920`) and never overflow horizontally.

### Requirement 7: Comprehensive Surface & Typography Coverage

All primary UI surfaces MUST respond to `DisplayScaleMetrics`:

- **Main Popover & `PanelView`**: Panel width, popover content size, tab bar (status dots, labels, pill padding, corner radius), detail header (account label, plan badge), stale/warning banners, empty state tile, `WindowRowView` (titles, percentages, countdown/basis, card padding, corner radius, `ProgressTrack` height), `MetricTile` (title, value, note, padding, corner radius), and `FooterBar` (refresh pill, updated timestamp, icon button sizes).
- **Settings Window & `SettingsPanelView`**: Window content size and `SettingsPanelView` root frame MUST share a single unified size (`metrics.settingsWindowSize`, base `360 × 520pt`, eliminating the legacy `340 × 480` vs `360 × 520` mismatch) across all display scales and clamped `visibleFrame` sizes; inner padding/spacing, headings, theme cards (accent dot, title, subtitle, padding, corner radius), toggle/caption text, provider rows, API key input/status text MUST scale proportionally.
- **About Window & `AboutPanelView`**: Window content size, spacing, heading, enlarged eye icon frame, app name, version, and subtitle text.
- **Development Panel (`USAGE_LENS_SHOW_PANEL=1`)**: Panel content size and embedded `PanelView` metrics.
- **Exclusion**: The macOS menu bar status item (`NSStatusItem` length `32` and `MenuBarIcon` `24 × 20`) MUST remain at standard macOS menu bar dimensions.

### Requirement 8: Dynamic Display Changes & Multi-Monitor Switching

UI surfaces MUST update their dimensions and font scaling dynamically without requiring an app restart.

- **Given** a multi-monitor setup (e.g., a 16" MacBook Pro and a 27" external monitor),
- **When** the user clicks the menu bar icon on the 27" monitor,
- **Then** the popover MUST resolve the screen owning the clicked `NSStatusBarButton` (`button.window?.screen`), read its logical size, visible frame, and `CGDisplayScreenSize`, update `popover.contentSize`, and render `PanelView` with that screen's `DisplayScaleMetrics`.
- **When** the user later clicks the menu bar icon on the 16" MacBook Pro screen,
- **Then** the popover MUST resize and re-render using the MacBook screen's `DisplayScaleMetrics`.
- **Given** an open Settings, About, or Development window,
- **When** the user drags the window to another monitor (`NSWindow.didChangeScreenNotification`) OR changes display resolution / connects / disconnects a monitor (`NSApplication.didChangeScreenParametersNotification`),
- **Then** the window MUST update its `DisplayScaleMetrics` and content size to match the new screen without triggering resize loops or losing window visibility.
- **And** when resizing an open window near any edge of the target screen (top/menu bar, bottom/Dock, left, or right), the resulting full window frame (including title bar) MUST be constrained completely within the target screen's `visibleFrame` (`minX >= visibleFrame.minX`, `maxX <= visibleFrame.maxX`, `minY >= visibleFrame.minY`, `maxY <= visibleFrame.maxY`) so the title bar and close button never move offscreen, and repeated resize calls MUST be idempotent.

### Requirement 9: Headless Fallback, Persistence & Compatibility

- **Given** a headless or test environment where `NSScreen` is unavailable (`nil`) or reports zero/non-finite logical dimensions,
- **When** `DisplayScaleMetrics` is resolved,
- **Then** it MUST safely fall back to `.standard` (`sizeScale = 1.0`, `fontScale = 1.0`) without crashing or producing `NaN`/`Infinity`.
- **Given** existing user preferences (`usageLens.theme`, `usageLens.providers`, Keychain DeepSeek API Key, Launch at Login),
- **When** theme switching or provider list changes occur,
- **Then** existing theme refresh (`ThemeChangeSignal` / `ThemeHostRegistrar`) and settings persistence MUST continue to work identically while preserving the active display's `DisplayScaleMetrics`.
- **Given** existing call sites such as `PanelView(store: store)`, `SettingsPanelView(launchAtLogin:)`, `AboutPanelView()`, and `DisplayScaleMetrics.make(displaySize:visibleSize:)`,
- **Then** all existing public initializers and factory calls MUST remain source-compatible (with `physicalSizeMM: CGSize? = nil` default and `@Environment(\.displayScaleMetrics)` defaulting to `.standard`).
