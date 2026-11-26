# Scan: 3D room capture (RoomPlan)

The **Scan** tab builds a **3D room model** with Apple’s **RoomPlan** (LiDAR). It is similar in spirit to Polycam’s Space mode, but it is **not** the Polycam app — it uses Apple frameworks only.

## What you get

| Feature | Requires | Notes |
|---|---|---|
| Walk-around room capture | LiDAR + RoomPlan | iPhone Pro / Pro Max (and supported iPad Pro) |
| Save USDZ on this iPhone | Same | Indexed under Application Support |
| Share USDZ | Same | System share sheet |
| Spoken summary | On-device model | Walls / doors / windows / furniture counts |
| iPhone Air | — | Scan disabled with an explicit warning |

## How to use

1. Open the **Scan** tab.
2. Accept the disclaimer (approximate model — not for construction or navigation).
3. Optionally name the scan.
4. Tap **Scan room** and walk slowly so walls and furniture are visible.
5. Tap **Done** when finished; Applebot processes, saves a USDZ, and speaks a short summary.
6. From **Saved scans**: Share, Summarize again, Rename, or Delete.

## Sensors

| Device | Behavior |
|---|---|
| iPhone Pro (+ LiDAR) | Full RoomPlan capture |
| iPhone Air / non-LiDAR | Warning; **Scan room** disabled |

## Privacy and safety

- Capture runs on-device via RoomPlan / ARKit.
- Saved USDZ files stay in Applebot’s app container unless you Share them.
- Spoken summaries use scan **counts and object labels** (text), not a cloud upload of the mesh — unless you enable an external chat model.
- Models are approximate. Not for construction documents, legal floor plans, or safety-critical navigation.

## Developer map

| Piece | Location |
|---|---|
| Capabilities | `ConnectorKit/SensorCapability.swift` (`RoomScanCapabilities`) |
| Facts / narration | `LLMKit/RoomScanSummary.swift` |
| Probe | `App/Services/RoomScanCapabilityProbe.swift` |
| Store | `App/Services/RoomScanFileStore.swift` |
| Controller | `App/Services/RoomScanController.swift` |
| Capture UI | `App/Views/RoomCaptureSessionView.swift` |
| Tab UI | `App/Views/ScanView.swift` |
| Tests | `tests/LLMKitTests/RoomScanSummaryTests.swift` |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Scan disabled / LiDAR warning | Expected on Air; use a Pro with LiDAR |
| Poor mesh | More light, slower walk, cover all walls |
| Save failed | Free storage; try again |
| No speech | Check volume; tap **Speak again** |