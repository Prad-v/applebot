# On-device model + sensor enhancement ideas

Product notes for features that stay on the iPhone: Apple’s Foundation Models plus sensors and frameworks Applebot already (or could) use. Nothing here is shipped unless listed in the [changelog](../CHANGELOG.md).

## Already in Applebot

| Capability | Used for |
|---|---|
| Foundation Models | Chat, summaries, briefs, rewrites |
| NaturalLanguage | Mood reading, embeddings |
| Speech + `AVSpeechSynthesizer` | Mic input, spoken replies |
| HealthKit | Steps, sleep, HR, workouts, clinical records (read-only) |
| Vision OCR | PDFs / photos into the knowledge base |
| EventKit | Calendar, Reminders, morning brief |
| Face ID | Family profile switch |
| Core Motion | Sedentary / activity summaries (Motion connector) |
| ARKit (+ LiDAR when present) | Trail AR overlay; mesh gated per device |
| Camera + Vision | Surroundings accessibility descriptions |

## Shipped

- **Health tab** — Apple Health dashboard, Applebot-only medications (manual + photo OCR), wellness score + model narrative. See [health.md](health.md).
- **Stocks tab** — watchlist, holdings, alerts, awareness. See [stocks.md](stocks.md).
- **Health follow-ups** — medication local reminders + Taken log, health lines in morning brief, 7-day wellness trend, Ask-from-Health → Chat.
- **Notification Taken + App Intents** — reminder action marks taken; Siri/Shortcuts for mark-taken and ask wellness score.
- **Behavioral patterns** — on-device twin card from Health / Calendar / chat (sleep, exercise, work window, interests, stress, spending hints). Sensors are summarized first; raw streams never enter the LLM. See [behavioral-profile.md](behavioral-profile.md).
- **Trail / wilderness** — GPS, waypoints, breadcrumbs, weather “here” + cache, offline OpenTopoMap packs, Motion sedentary check, AR trail overlay with LiDAR mesh gated (warn + disable on Air). See [wilderness.md](wilderness.md).
- **Surroundings** — camera + Vision + on-device narration + speech for blind / low-vision scene understanding, including **Live mode** (change-gated continuous updates; LiDAR assist when present). See [surroundings.md](surroundings.md).
- **Scan** — RoomPlan 3D room capture (LiDAR Pro), USDZ library, spoken summary. See [scan.md](scan.md).

## High-leverage next steps

1. **Focus / quiet hours** — skip Sleep Focus / late night for check-ins and med pings.
2. **Richer sleep window** — bedtime/wake from HealthKit sleep samples (not only nightly duration).
3. **Mood × vitals soft check-in** — gentle unlock prompt when chat mood and sleep/RHR both look rough.

## Further ideas (opt-in)

| Idea | Sensors / APIs | Model role |
|---|---|---|
| Recovery / stress check-in | HRV, sleep + chat mood | Soft prompt when vitals and tone both look rough |
| Place-aware prep | Significant-change / geofence location | “Near clinic — open Health pack notes?” |
| Sedentary nudge (shipped soft check) | Core Motion / pedometer | Optional automation + Trail / chat; not a nagging push |
| Shorter spoken replies in noise | On-device SoundAnalysis / mic level | Adapt TTS length; audio never leaves device |
| Live label / whiteboard Q&A | Camera + Vision | OCR into the open chat or a pack |
| Thermal / battery honesty | `ProcessInfo` thermal, battery | Defer heavy reindex or long generation |
| Watch glance brief | WatchConnectivity | Brief on watch; deep chat on phone |
| More Siri phrases | App Intents | Sleep / week trend / open Health pack |

## Privacy rules of thumb

- Same bar as connectors: explicit Connect / toggles; airplane-mode purity when sensors are off.
- Prefer pack-scoped context (Health vs Work) and family profile isolation.
- Writes (reminders, calendar) still require in-app approval of exact content.
