# Surroundings: scene description for accessibility

The **Surroundings** tab helps blind and low-vision users understand what is in front of the iPhone. It captures a still frame, runs **on-device Vision**, optionally notes **LiDAR** availability, then asks Apple’s on-device model for a short spatial description and **speaks** it.

## What you get

| Step | What happens | Leaves the device? |
|---|---|---|
| Safety note | First-run disclaimer (assistive only, not for navigation) | No |
| Camera | Live preview + still capture | No |
| Vision | Scene labels, OCR text, approximate people count | No |
| LiDAR (Pro) | Depth-assist note when hardware supports it | No |
| Narration | On-device model (or mechanical fallback) | No (unless you enabled an external model) |
| Speech | Spoken description via Applebot voice | No |

## How to use

1. Open the **Surroundings** tab.
2. Read and accept the safety note (**I understand — continue**).
3. Allow **Camera** when iOS asks.
4. Point the rear camera at the area you care about.
5. Either:
   - Double-tap **Describe what’s around me** for a single description, or
   - Turn on **Live mode** for continuous spoken updates when the scene changes (no need to tap each time).
6. Listen to the spoken description, or use **Speak again** / VoiceOver on the on-screen text.
7. Turn **Live mode** off, tap **Stop live**, or leave the tab to stop continuous updates.

## Live mode

Live mode samples the camera about every 2 seconds, runs on-device Vision, and speaks only when labels, people count, or visible text meaningfully change. Spoken updates are short (1–2 sentences) and throttled so they do not talk over each other.

| Behavior | Detail |
|---|---|
| Change gate | Ignores tiny confidence noise; speaks on new labels / people / OCR |
| Speech | Waits while the previous utterance is still speaking; ~6s minimum between speaks |
| Thermal | Pauses automatically if the iPhone is seriously warm |
| Leave tab | Live mode stops |
| Model | Prefers on-device model; mechanical fallback if unavailable |

## Sensors and warnings

| Capability | Typical iPhone Air | Typical Pro |
|---|---|---|
| Camera + Vision description | Yes | Yes |
| LiDAR depth assist | **No** — warning shown; describe still works | Yes — approximate depth note |

Missing sensors disable **only that slice**. Camera description keeps working without LiDAR.

## Privacy and safety

- The photo is analyzed **on this iPhone**. Raw frames are not uploaded by Applebot’s Surroundings flow.
- Only a **text fact sheet** (labels, OCR snippets, counts) is given to the model — not the image bytes.
- If you switch on an **external model**, that text fact sheet would leave the device like other chat prompts. Prefer Apple Intelligence for this tab.
- **Assistive only.** Do not use descriptions for street crossing, stairs, or other safety-critical navigation. Carry proven mobility aids.

## Developer map

| Piece | Location |
|---|---|
| Fact sheet + prompts | `LLMKit/SurroundingsScene.swift` |
| Capabilities | `ConnectorKit/SensorCapability.swift` (`SurroundingsCapabilities`) |
| Vision analyze | `App/Services/SurroundingsVisionAnalyzer.swift` |
| Tab controller | `App/Services/SurroundingsController.swift` |
| UI + camera | `App/Views/SurroundingsView.swift`, `SurroundingsCameraPreview.swift` |
| Tests | `tests/LLMKitTests/SurroundingsSceneTests.swift` |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Camera denied | Settings → Applebot → Camera → on |
| “Describe surroundings unavailable” | Device/build lacks Vision; use a real iPhone |
| LiDAR warning | Expected on Air / non-Pro; description still works |
| Empty / weak description | More light, hold steadier, point at the subject; try again |
| External model banner | Turn off external model under You for fully on-device narration |