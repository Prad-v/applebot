# Health tab

Applebot’s **Health** tab shows Apple Health activity and vitals on this iPhone, lets you keep an **Applebot-only** medication list (manual or label photo), and builds a **wellness score** plus a short on-device model narrative. Nothing is written back to Apple Health.

## Requirements

- Connect Apple Health (same permission flow as **You → Connectors → Apple Health**).
- Clinical **Health Records** appear only if you’ve linked a provider in the Health app and allowed those categories.
- Medications, scores, and narratives stay in Applebot storage (SwiftData / in-memory for UI tests).

## What you see

1. **Disclaimer** — Applebot is not a medical device and does not give medical advice.
2. **Wellness score (0–100)** — transparent formula from today’s steps, sleep, resting heart rate, and activity. Tap through the components to see the points.
3. **Last 7 days** — daily wellness scores (and steps) so trends are visible beyond today.
4. **Awareness** — on-device model narrative that explains the score and gives *general* notes about confirmed medications (typical uses / commonly discussed side effects). Always ends with a disclaimer.
5. **Ask Applebot** — opens Chat with a scoped prompt (score, week, or medications).
6. **Today** — steps, energy, sleep, heart rate, SpO₂, weight, workouts from Apple Health (read-only).
7. **Medications** — your Applebot list. Add manually or from a photo; swipe to delete; tap **Taken** to log a dose locally.
8. **Health Records** — allergies / conditions / labs when available from Apple Health.

## Medications

| Path | Flow |
|---|---|
| Manual | **Add medication** → name, dose, frequency, notes → Save |
| Photo | **Add from photo** → on-device Vision OCR → model structures a draft → **you confirm** → Save |
| Reminders | Optional daily local notifications at `HH:mm` times (this iPhone only) |
| Taken | **Taken** on the Health row, on the notification action, or via Siri / Shortcuts |
| Siri / Shortcuts | “Mark metformin taken in Applebot”, “What’s my wellness score in Applebot” |
| Storage | SwiftData on this iPhone only; scoped to the active family profile |

Label photos may also be filed into the **Health** document pack for auditability. OCR drafts are never treated as truth until you confirm.

## Morning brief

When **Morning brief on unlock** is enabled, the sheet can include a short **Health** block (wellness score, sleep, steps, resting HR, and which meds have reminders on) built from the same on-device data.

## Notifications and Siri

- Medication reminder banners include a **Taken** action (marks the dose without opening the full editor).
- Tapping the banner opens the **Health** tab.
- App Intents (Shortcuts / Siri): **Mark medication taken** and **Ask about wellness score**. Actions are queued on-device and applied when Applebot is active.

## Chat integration

- A compact health + medications block is added to personal chat context (token-budgeted).
- Tool `list_user_medications` lists confirmed Applebot meds, reminder times, and “taken today” when known (alongside existing `health_*` Apple Health tools when the connector is on).
- **Ask Applebot** on the Health tab (or the wellness-score Shortcut) switches to Chat and starts a new conversation with a prepared prompt.

## Privacy and safety

- HealthKit remains **read-only**.
- Model medication notes are **general information**, not instructions to start, stop, or change a dose.
- Verify anything clinical with a clinician or pharmacist.
- App Store clinical Health Records use sits under guideline 5.1.3; keep a privacy policy URL for submission.

## Code map

| Piece | Location |
|---|---|
| Wellness score | `LLMKit/WellnessScore.swift` |
| Meds + insight prompts | `LLMKit/Medication.swift` |
| SwiftData model | `App/Models/MedicationRecord.swift` |
| Stores / dashboard | `MedicationStore`, `HealthDashboardController` |
| UI | `App/Views/HealthView.swift` |
| Tests | `tests/LLMKitTests/HealthMedicationTests.swift`, UI smoke in `ApplebotUITests` |
