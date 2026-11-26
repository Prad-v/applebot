# Behavioral profile (on-device twin card)

Applebot learns a compact **behavioral patterns** card so chat can feel more like you — without uploading sensor streams or fine-tuning a cloud model.

## What it stores

| Field | How it is learned |
|---|---|
| Typical sleep hours | Median/average of last ≤14 Health day samples (needs ≥3 nights) |
| Exercise days / week + steps | Workout flags and step averages from Health |
| Workday calendar window | First/last timed Calendar event hours (weekday samples) |
| Top interests | Keyword + intent + tool classification on each chat turn |
| Travel affinity | Share of travel-related mentions vs other chat signals |
| Stress note | Repeated distressed messages; optional link to short sleep |
| Spending hints | Repeated money / shopping language (not bank sync) |

Raw observations stay on-device in `BehavioralObservationLog` (capped). The prompt only sees the summarized lines from `BehavioralProfile.render` (~100 tokens).

## What it is not

- Not Safari search history, Maps trajectories, or bank transactions
- Not a fine-tuned “clone” model — Style Card still owns “write like me”
- Not continuous GPS/IMU into the LLM (summarize first; see [on-device-enhancements](on-device-enhancements.md))

## Pipeline

1. **Health / Calendar refresh** — unlock brief or **You → Behavioral patterns → Refresh** builds `BehavioralDaySample`s.
2. **Each chat turn** — `ChatController` records `BehavioralTurnSignal` (question, intent, emotion, tools, search query).
3. **`BehavioralSummarizer`** — merges observations and recomputes summary fields.
4. **`personalContextBlock`** — appends the behavioral block beside profile, memory, health, and stocks.

## Privacy

- Per family profile (Face ID switch scopes the card)
- Included in encrypted `.applebotpack` vault (format v2; v1 packs restore with an empty card)
- Cleared with **Delete all data** or **Clear behavioral data**
- Toggle **Use behavioral patterns in chat** to stop injecting without wiping history

## Developer map

| Piece | Location |
|---|---|
| Types + summarizer | `ios/Kit/LLMKit/BehavioralProfile.swift` |
| Store | `ios/App/Services/BehavioralProfileStore.swift` |
| UI | `ios/App/Views/BehavioralProfileView.swift` |
| Wiring | `AppEnvironment.personalContextBlock`, `refreshBehavioralProfile()`, `ChatController` |
| Vault | `PersonalVaultPayload.behavioralProfile` (formatVersion 2) |

Tests: `tests/LLMKitTests/BehavioralProfileTests.swift`, vault coverage in `ContinuityTests.swift`.

```bash
docker compose run --rm test
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Always “Learning” | Connect Apple Health; wait ≥3 days of sleep/activity, or chat more so interests appear |
| No work window | Connect Calendar and have timed (non–all-day) events |
| Stress note missing | Distressed messages need intensity ≥3, at least twice |
| Spending note missing | Need several turns that mention budgets, purchases, or shopping |
