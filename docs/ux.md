# UX

Applebot uses a **lightweight companion** pattern: flat surfaces, typography hierarchy, and hairline separators — not nested cards or heavy chrome.

## Navigation

Eight tabs:

| Tab | Purpose |
|---|---|
| **Chat** | Large-title home, flat conversation rows, airy empty state |
| **Library** | Documents and packs with minimal pills and list rows |
| **Health** | Apple Health readouts, Applebot-only meds, wellness score + narrative |
| **Stocks** | Watchlist, holdings, alerts, market awareness + Ask |
| **Trail** | GPS, waypoints, breadcrumbs, offline topographic maps, AR overlay |
| **Surroundings** | Accessibility: describe what’s in front of the camera (Vision + speech) |
| **Scan** | RoomPlan 3D room capture (LiDAR), USDZ save/share, spoken summary |
| **You** | Profile line + grouped settings |

## Themes

Under **You → Theme**, pick an appearance that keeps text readable:

| Theme | Behaviour |
|---|---|
| **System** | Follows iOS Light/Dark; teal accent; adaptive primary text |
| **Daylight** | Always light; charcoal on white |
| **Midnight** | Always dark; soft white on charcoal |
| **Ocean** | Always light; deep blue accent |
| **Forest** | Always light; green accent |
| **High contrast** | Always light; black text and strong accent |

Choice is stored on-device (`appearanceTheme` in UserDefaults). The app applies `preferredColorScheme` and tint from the selection.

## Design system

SwiftUI tokens live in `ios/App/Theme/`:

- `AppearanceTheme` / `ThemeController` — selectable palettes
- `ApplebotTheme` — spacing, type, and colours resolved from the active theme
- `ApplebotComponents` — compact CTAs, text-forward suggestions, quiet banners

Canvas uses the theme canvas colour (system background for System).

## Principles

1. **Readable ink** — primary text uses theme `ink` (adaptive `Color.primary` for System), never a fixed dark grey on dark mode.
2. **Typography over boxes** — rows and sheets lead with type; avoid material cards and shadows.
3. **Hairlines, not frames** — dividers and quiet fills instead of stroked cards.
4. **Compact controls** — smaller composer icons, capsule CTAs, uppercase micro-labels.
5. **Minimal motion** — no looping pulse on empty/lock heroes.
6. **Accessibility IDs preserved** for UI tests (`theme-link`, `theme-*`, `new-chat`, `message-field`, `send`, `mic`, `attach`, `chat-options`, `delete-chat`, `health-connect`, `wellness-score`, `health-week-trend`, `ask-health-score`, `add-medication`, connectors, approvals).
