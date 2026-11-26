# Changelog

All notable changes to Applebot are documented here. Versions follow semantic versioning.

## 0.18.0

### Added
- **Scan tab**: Apple **RoomPlan** 3D room capture (LiDAR Pro), on-device USDZ save/share, rename/delete library, and spoken layout summary via the on-device model.
- LiDAR / RoomPlan capability gating with warnings on iPhone Air and other unsupported devices (scan disabled; other tabs unchanged).
- Docs: [docs/scan.md](docs/scan.md); UX, user guide, architecture, and site updated.

## 0.17.0

### Added
- **Surroundings Live mode**: continuous camera frames with on-device Vision; speaks short updates only when the scene meaningfully changes (no tap every time). One-shot **Describe** remains available.
- Live updates skip while TTS is speaking, throttle spoken cadence, pause on serious thermal state, and stop when leaving the tab.
- Docs / site updated for Live mode.

## 0.16.0

### Added
- **Surroundings tab** (accessibility): camera capture → on-device Vision (scene labels, OCR, people count) → on-device model narration → spoken description. LiDAR depth assist noted when available; warned and skipped on iPhone Air.
- Safety-first disclaimer; VoiceOver announcements; raw frames stay on-device (text facts only to the model).
- Docs: [docs/surroundings.md](docs/surroundings.md); UX, user guide, architecture, and site updated.

## 0.15.0

### Added
- **Motion connector** (Core Motion): soft sedentary check from pedometer + activity classification; chat tools `motion_sedentary` and `motion_capabilities`. Missing sensors disable only that slice with on-device warnings.
- **AR trail overlay** on the Trail tab: camera HUD with waypoint bearings. **LiDAR depth mesh** enabled on Pro models; on iPhone Air / non-LiDAR devices the mesh toggle is disabled with an explicit warning while compass AR still works.
- Sensor capability model (`MotionCapabilities` / `TrailARCapabilities`) shared by Trail UI and connectors.
- Optional automation template: Afternoon stretch check.
- Docs: wilderness, connectors, user guide, architecture, on-device enhancements, and site updated.

## 0.14.0

### Added
- **Trail tab**: GPS position, waypoints, breadcrumb trail, bearings, and **offline topographic map packs** (OpenTopoMap tiles downloaded while online, then used with no signal).
- **Google Maps–style offline download**: pan/zoom under a fixed selection frame, live size estimate, Overview/Standard/More detail, rename/update/delete downloaded areas.
- **Location connector** (on-device): chat tools for current fix, waypoints, bearing/distance, breadcrumbs, and map-pack list. Coordinates never leave the device.
- **Weather “here” + cache**: forecast from GPS; last successful forecast kept for offline answers.
- Docs: [docs/wilderness.md](docs/wilderness.md); connectors, architecture, user guide, and site updated.

## 0.13.0

### Added
- **Behavioral patterns** (on-device twin card): learns typical sleep, exercise/steps, calendar work window, chat interests, travel affinity, stress tone, and spending hints; injects a ~100-token summary into chat. Settings under **You → Behavioral patterns**; included in vault format v2.
- Docs: [docs/behavioral-profile.md](docs/behavioral-profile.md); personalization, architecture, continuity, user guide, and site updated.

## 0.12.0

### Added
- **Stocks tab**: on-device watchlist and holdings, batch Yahoo quote refresh, market-session label, awareness narrative, Ask Applebot prompts, confirm-first suggested adds/alerts, threshold and event alerts (local notifications + best-effort BGAppRefresh), Daily Brief markets lines, Friday portfolio automation template, and Siri/Shortcuts for watchlist / quote / portfolio.
- Chat tools `list_watchlist` / `list_holdings` and connector tool `stock_quotes`; stocks context in the personal prompt block.
- Docs: [docs/stocks.md](docs/stocks.md); site, user guide, connectors, continuity, architecture updated.

## 0.11.3

### Changed
- **Response quality**: intent-aware instruction budgets (compact Warm/Coach persona on RAG and tool turns), task-aware sampling temperature and max answer length, and a one-shot grounded citation verify/retry.
- Broader local document-intent hints (`explain…`, `what's the…`, handbook/policy phrasing).
- Docs / site: [docs/response-quality.md](docs/response-quality.md), architecture, emotional chat, user guide, changelog.

## 0.11.2

### Added
- **Taken on medication notifications**: reminder banners expose a **Taken** action; tapping the banner opens Health.
- **App Intents / Siri / Shortcuts**: “Mark medication taken” and “Ask about wellness score” (queued on-device, applied when Applebot is active).

### Changed
- Docs / site: [docs/health.md](docs/health.md), user guide, changelog.

## 0.11.1

### Added
- **Medication reminders**: optional daily local notifications (`HH:mm`) and **Taken** logging (Applebot-only).
- **Health in morning brief**: sleep / steps / resting HR / wellness score / med-reminder names when brief is on.
- **7-day wellness trend** on the Health tab.
- **Ask Applebot** from Health (score / week / medications) opens Chat with a prepared on-device prompt.

### Changed
- Docs / site: [docs/health.md](docs/health.md), user guide, changelog.

## 0.11.0

### Added
- **Health tab**: Apple Health activity/vitals (read-only), clinical records when linked, Applebot-only medications (manual or label photo with Vision OCR + confirm), transparent wellness score, and on-device model awareness narrative with medical disclaimer.
- Chat context + `list_user_medications` tool for confirmed Applebot meds.
- Docs: [docs/health.md](docs/health.md); site and UX updated for the fourth tab.

## 0.10.2

### Added
- **Delete chat from inside a conversation**: ⋯ → **Delete Chat**, with a confirmation alert; returns to the chat list and removes messages on-device.
- Chat list **context menu** for pin / delete (in addition to swipe actions). Swipe-delete now pops navigation if that chat was open.

### Changed
- Docs / site: user guide, UX accessibility IDs, features, changelog.

## 0.10.1

### Fixed
- **Mic no longer auto-starts after typed chats.** Hands-free resume only arms after a mic utterance (`markVoiceTurn`); typed / programmatic sends call `noteTypedInput()` so Speak replies alone cannot open the microphone.
- Removed the Hands-free toggle from the chat **+** menu (it remains under **You → Voice**) to avoid accidental enablement.

### Changed
- Docs / site: [docs/voice.md](docs/voice.md), user guide, changelog.

## 0.10.0

### Added
- **Theme settings** (You → Theme): System, Daylight, Midnight, Ocean, Forest, and High contrast — persisted on-device with readable text on each canvas.

### Changed
- **Companion UX redesign**: Chat / Library / You tabs with a lightweight modern pattern — flat lists, hairlines, compact composer, typography-led empty states (no heavy cards or glow).
- Text colours resolve from the active theme (fixes hard-to-read fixed ink in Dark Mode).
- Docs: [docs/ux.md](docs/ux.md); user guide and site updated for navigation and themes.

## 0.9.0

### Added
- **Apple Health (HealthKit) connector**: read steps, sleep, heart rate, workouts, vitals and clinical health records in chat (on-device, read-only). Tools: `health_summary`, `health_list_samples`, `health_list_workouts`, `health_list_records`.
- Intent router recognises health questions so tools stay available under the on-device context budget.
- HealthKit + Clinical Health Records entitlements; clinical usage string; two-step Connect (vitals first, then clinical) on the main actor.
- Docs and site user guide updated.

## 0.8.0

### Added
- **Reminders connector**: list incomplete to-dos, add reminders, and mark them done (approval for writes). On-device EventKit; feeds the morning brief.
- Docs updated for Reminders tools and troubleshooting.

## 0.7.0

### Added
- **Document packs UI**: filter, create packs, and move documents (first-class `pack` field; legacy title prefix still works).
- **Gentle check-ins**: opt-in relationship continuity prompts from open loops / near-term events.
- **Retrieval retune**: thumbs up/down on document answers adapt hybrid vector/keyword weights on-device per profile.
- **Family profiles**: multiple profiles on one iPhone with Face ID to switch; scoped memory, prefs, docs, chats.
- **Encrypted backup**: export/import `.applebotpack` (AES-GCM + password) for profile, memories, style, automations, optional docs.
- **Local automations**: Sunday-style recipes offered on unlock; nothing runs until you confirm.
- Docs: [docs/continuity.md](docs/continuity.md).

## 0.6.0

### Added
- **Personal profile**: name, roles, city, reply style, boundaries, and preference confirmation (Settings → Your profile).
- **Ranked memory with expiry**: typed facts (`person`, `event`, `openLoop`, `place`, `project`, …), confidence, `lastUsedAt`, and automatic expiry for time-bound facts.
- **Morning / unlock brief** (opt-in): once per day from Calendar + open loops.
- **Voice note → RAG pack**: + → Voice note… structures speech into the Voice notes document pack.
- **Write like me**: on-device style card; `rewrite this: …` uses your samples without cloud fine-tuning.
- **Local intent router**: skips RAG/tools when the message is chat, emotional, or rewrite so the on-device window stays useful.
- Docs: [docs/personalization.md](docs/personalization.md).

### Changed
- Personal context shares ~200 tokens between profile (~80) and ranked memories.
- Preference facts wait for confirmation instead of silent injection.
- Delete-all also clears profile, style card, and brief history.

## 0.5.0

### Added
- **Long-term memory**: durable facts across chats, stored on-device in SwiftData. Settings → What Applebot remembers to review, pin, delete, or turn off.
- Memory extraction after each turn (on-device model + heuristic fallback); injected into prompts with a small token budget.
- **Voice conversation**: mic button with **on-device-only** speech recognition (cloud recognition is refused).
- **Speak replies** via on-device `AVSpeechSynthesizer`, and optional **Hands-free** listen-after-speak loop.
- Docs: [docs/memory.md](docs/memory.md), [docs/voice.md](docs/voice.md).

### Changed
- Delete-all also clears remembered facts. Backgrounding stops listening and speaking.

## 0.4.0

### Added
- **Live data connectors**: **Weather** (Open-Meteo), **Stocks** (Yahoo Finance) and **Web search** (Brave Search API). Off until you switch them on; only the place, ticker or query leaves the device.
- Weather and Stocks need no API key. Web search is enabled with build setting `BRAVE_API_KEY` (see [connectors](docs/connectors.md)).
- The tool prompt tells the model never to invent weather, prices, news or recent events when a live tool can help.
- **External models**: Settings → External model lets you switch chats from Apple Intelligence to **OpenAI** or **Anthropic** with your own API key.
- Per-provider model name and optional base URL (OpenAI-compatible proxies and local servers). API keys are stored only in the Keychain on this iPhone.
- While the switch is on, chats stream from the configured provider; turn it off to return to the on-device model. Connectors and document search keep working with either backend.
- Documentation: [docs/connectors.md](docs/connectors.md), [docs/external-models.md](docs/external-models.md).

### Changed
- Settings shows the active model (on-device or external). Chats show a small notice when messages leave the iPhone for an external provider.
- Network summary in Settings reflects an enabled external model as well as connectors that use the network.

## 0.3.0

### Added
- **Connectors**: Applebot can now use **Gmail** and your **Calendar** when you ask (Settings → Connected services → Connectors). Off until you connect them, and each can be paused without signing out.
- **Calendar**: ask about your schedule, and add events. Reads stay on the iPhone.
- **Gmail**: search and read your email, and save a reply draft. Applebot never sends email.
- **Approvals**: anything that changes something (saving a draft, adding an event) shows the exact content first and only happens if you approve. Declining, dismissing the sheet, or leaving the chat all mean no.
- Replies that used a connector say which one ("Searching Gmail").
- A notice in chats that search your documents explains that connectors are paused, with a one-tap **Use Gmail and Calendar instead**.
- New `ConnectorKit` library (OAuth 2.0 with PKCE, Keychain token storage, connector registry) and tool calling in `LLMKit` (`ToolSpec`, `ToolGuard`, Foundation Models adapter).
- Documentation: [docs/connectors.md](docs/connectors.md). New build setting `GOOGLE_CLIENT_ID` for Gmail.

### Changed
- "Network: Not used" in Settings now reads "Only for connectors you turned on" while a Gmail-style connector is on. With connectors off the app still makes no network requests.
- "Delete all chats and documents" also signs out of connected accounts and removes their tokens.

### Security
- Email content is treated as untrusted data; there is no tool that sends, deletes or forwards mail, so a malicious email cannot make Applebot send anything.

## 0.2.0

### Added
- **New chat from inside a conversation**: a compose button in the chat toolbar starts a brand new, empty conversation (no history, no summary, search scope reset to all documents). Back returns to the chat list.
- **Attach documents to a chat** with the **+** button next to the message box: Files, Photos (on-device OCR), Paste text, or pick from your library.
- Attached documents show as chips above the message box. Tap to change the scope, or tap the x to remove one.

### Changed
- Attaching documents to a chat narrows that chat's search to the attached documents. Removing the last one returns to "all documents".
- Empty chats that never received a message are no longer saved or listed.
- Documents deleted from the library are dropped from any chat's scope automatically.

## 0.2.1

### Changed
- Warm companion is now the default conversation style.
- Warm and coach personas answer "how are you?" / "how are you feeling?" in character instead of saying they have no feelings.
- Detects check-in questions about the bot and injects first-person companion guidance; skips document search for those turns.
- Slightly higher sampling temperature for warm and coach styles so replies feel less flat.

## 0.2.0

### Added
- Emotional chat: **Settings → Conversation style** with Neutral, Warm companion and Supportive coach.
- On-device mood reading (sadness, anxiety, anger, joy) that adapts the reply's tone and length.
- Distressed messages skip the document search so Applebot talks instead of answering "not found".
- Emotion-aware empty chat ("How are you feeling today?") with conversation starters.

### Changed
- When Apple's safety guardrails decline a message, Applebot now responds kindly and suggests rephrasing.

## 0.1.0

First working version.

### Added
- Offline chat with Apple's on-device language model (Foundation Models), with streaming answers.
- Saved conversations with search, pinning, and swipe-to-delete.
- Rolling conversation summary so long chats survive the model's small context window.
- Private document library: import PDF, text, Markdown, RTF, and images (on-device OCR), or paste text.
- Hybrid retrieval (semantic vectors + BM25 keywords) with MMR de-duplication.
- Grounded answers with source citations and a "Why this answer?" sheet.
- Per-chat search scope (all documents or a chosen subset).
- Optional Face ID / passcode lock, encrypted-at-rest storage, and a "delete everything" action.
- Availability banner explaining when Apple Intelligence is unavailable.
- Retrieval-quality evaluation (recall@k, MRR) and a CI gate on it.
