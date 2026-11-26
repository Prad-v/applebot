# Stocks tab

Applebot’s **Stocks** tab is a personal markets dashboard on this iPhone: a **watchlist**, optional **holdings** you type in (not broker-synced), **threshold alerts**, and a short on-device **awareness** note from model recommendations. Live prices still come from the **Stocks** connector (Yahoo Finance). Quotes can be delayed. **Not financial advice.**

## Requirements

- Turn on **You → Connectors → Stocks → Use in chats** (or **Enable Stocks** on the tab).
- Network only when refreshing quotes or when chat tools look up a ticker.
- Watchlist, holdings, and alert rules stay in Applebot SwiftData, scoped to the active family profile.

## What you see

1. **Disclaimer** — delayed quotes; Applebot is not a broker and does not give financial advice.
2. **Today** — US session heuristic (pre-market / open / after hours / closed), movers summary, last refresh time.
3. **Awareness** — on-device model narrative over loaded quotes + holdings (confirm-first suggestions appear separately).
4. **Ask Applebot** — opens Chat with a scoped prompt (movers, watchlist, holdings P&amp;L, or “what moved and why”).
5. **Suggested adds / alerts** — confirm cards before anything is saved.
6. **Watchlist** — symbols you track; swipe to delete; **Suggest alert** proposes rules you must confirm.
7. **Holdings** — optional shares + average cost; local unrealized P&amp;L; soft concentration note when one name dominates.
8. **Alerts** — price above/below, day-move %, near 52-week extreme, or an event/earnings date.

## Tracking

| Path | Flow |
|---|---|
| Watchlist | **Add to watchlist** → symbol (+ optional name/group) → Save |
| Holdings | **Add holding** → symbol, shares, average cost → Save (also adds the symbol to the watchlist if missing) |
| Suggested add | Confirm **Add** on a pending card (never silent) |
| Storage | SwiftData on this iPhone only; scoped to the active family profile |

## Monitoring

- Batch quote refresh for the whole watchlist/holdings set (`stock_quotes` / dashboard batch).
- Last-known quotes cached on-device for offline / morning brief.
- Foreground / unlock refresh when Stocks is enabled.
- Morning brief can include a short **Markets** block (session + movers).
- Optional automation template **Friday portfolio wrap-up** (off by default; confirm before run).

## Alerting

| Kind | Behavior |
|---|---|
| Price above / below | Fires when a refreshed quote crosses the threshold |
| Day move % | Fires when absolute day % change ≥ threshold |
| Near 52-week | Fires when within N% of the 52-week high or low |
| Event date | Local calendar notification on the morning of the date |

- Evaluation runs on dashboard refresh and (best-effort) via **BGAppRefresh** — iOS may defer background work; there is no push server.
- Quiet hours (22:00–07:00 local) suppress price alerts; event-date reminders still schedule.
- Notification actions: **Ask Applebot**, **Snooze**; tap opens the Stocks tab.

## Model recommendations

- Structured quotes + holdings → short awareness narrative (same pattern as Health).
- **Ask Applebot** buttons hand off to Chat with prepared prompts (tools may call `stock_quote` / `stock_quotes` / web search).
- Suggested watchlist adds and alert rules always require **Add** / **Create alert**.
- Never frames output as a trade recommendation.

## Chat integration

- Compact stocks block in personal chat context (token-budgeted).
- Tools: `list_watchlist`, `list_holdings` (plus connector `stock_quote` / `stock_quotes` when Stocks is on).
- Intent router treats watchlist / portfolio / share-price-alert phrasing as live-data (tools on).

## Siri / Shortcuts

- **Open watchlist**
- **Ask about a stock** (symbol)
- **Ask about portfolio**

Actions are queued on-device and applied when Applebot is active.

## Privacy and safety

- Only tickers / company names leave the device for Yahoo Finance (and search queries if Web search is on).
- No broker login, no trading, no write tools to a brokerage.
- Holdings are user-entered estimates, not account sync.
- Always show delayed-quote + not-financial-advice language on the tab, alerts, narratives, and tools.

## Code map

| Piece | Location |
|---|---|
| Portable types / evaluator / insight | `LLMKit/StocksTracking.swift` |
| Yahoo connector + batch | `ConnectorKit/StocksConnector.swift` |
| SwiftData models | `WatchlistItem`, `HoldingRecord`, `StockAlertRule` |
| Stores / dashboard | `WatchlistStore`, `HoldingsStore`, `StockAlertStore`, `StocksDashboardController` |
| Notifications / BG refresh | `StocksAlertScheduler`, `StocksBackgroundRefresh` |
| UI | `App/Views/StocksView.swift` |
| Tests | `tests/LLMKitTests/StocksTrackingTests.swift`, batch coverage in `LiveDataConnectorTests`, UI smoke in `ApplebotUITests` |
