# Voice conversation

Talk to Applebot and hear replies. Speech recognition and spoken answers are designed to stay **on this iPhone**.

## Using it

1. In a chat, tap the **mic** next to the message field. Speak, then tap the mic again (or wait for end-of-utterance).
2. The transcript is sent like a typed message.
3. With **You → Voice → Speak replies** on (default), Applebot reads the answer aloud.
4. Turn on **Hands-free conversation** (under **You → Voice**) to listen again automatically after each **voice** turn. Typing a message never opens the mic — only a mic-started utterance arms the resume loop. Tap **Stop** or leave the chat to end the loop.

## Privacy

| Setting | Behaviour |
|---|---|
| On-device speech available | Mic works. `SFSpeechRecognizer` runs with `requiresOnDeviceRecognition = true`. |
| On-device speech unavailable | Mic is refused with an explanation. Applebot will **not** fall back to cloud recognition. |
| Speak replies | `AVSpeechSynthesizer` — fully on-device, no network. |

Permission strings explain that audio stays on-device (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`).

Listening stops when the app goes to the background or the screen locks (and Face ID lock can engage).

## Settings

| Setting | Default | Meaning |
|---|---|---|
| Speak replies | On | Read assistant answers aloud |
| Hands-free conversation | Off | After a **voice** turn’s spoken reply, start listening again (typed chats stay silent on the mic) |
| On-device speech | Read-only | Whether the current language supports on-device recognition |

## Implementation

- `ios/App/Services/VoiceController.swift` — listening, speaking, hands-free resume
- Listening records with `AVAudioRecorder`, then transcribes with `SFSpeechURLRecognitionRequest` (avoids `AVAudioEngine.installTap`, which can abort the app)
- Tap mic to start, tap again to stop and send
- Mic + status line in `ChatView`; **+** menu also has Speak… (Hands-free lives only under **You → Voice** so it is not toggled by accident)
- Hands-free resume is armed only when `markVoiceTurn()` runs from a mic utterance; typed sends call `noteTypedInput()` so Speak replies alone never opens the mic
- Stop cancels generation, listening and speech together

## Limits

- Accents and noisy rooms affect recognition quality.
- Long answers are spoken in full; tap Stop to interrupt.
- Hands-free can pick up TV or other voices; use it in a quiet place.

## Troubleshooting

| Problem | Fix |
|---|---|
| Mic does nothing / “unavailable” | Your locale may lack on-device recognition. Type instead, or check iOS language settings |
| No mic button in the chat bar | Update to the latest build (`make sim` / `make device`). The mic is to the left of Send; **+** also has **Speak…** |
| Voice on Simulator | Simulator builds allow speech recognition without the on-device-only lock (device builds stay on-device). Enable **I/O → Audio Input** in the Simulator menu |
| “Microphone is not ready” on Simulator | Enable **I/O → Audio Input** in the Simulator menu, or test on a physical iPhone |
| App crashes on mic tap | Install the latest build (`make device`). Older builds used `AVAudioEngine.installTap` from a `@MainActor` type and trapped with `EXC_BREAKPOINT` / `_dispatch_assert_queue_fail` |
| No permission sheet | Settings → Applebot → Microphone / Speech Recognition |
| No spoken reply | Enable **Speak replies**; confirm Silent Mode / volume |
| Keeps listening forever | Turn off Hands-free under **You → Voice**, or tap Stop |
| Mic opens after a typed reply | Hands-free only resumes after a mic turn; turn Hands-free off if you do not want that loop |

## Debugging a device crash

1. Reproduce on the phone (USB cable, Developer Mode on).
2. Pull crash logs:

```bash
mkdir -p /tmp/applebot-device-crashes
xcrun devicectl device copy from \
  --device "Pradeepkumar’s iPhone" \
  --domain-type systemCrashLogs --source / \
  --destination /tmp/applebot-device-crashes
ls -lt /tmp/applebot-device-crashes/Applebot-*.ips | head
```

Or Xcode → **Window → Devices and Simulators** → select the iPhone → **Open Console** / device logs → open the latest `Applebot` `.ips`.

3. Look at the **faulting thread**. The old mic bug looked like:

```
_dispatch_assert_queue_fail
swift_task_checkIsolatedSwift
VoiceController.beginRecognition …
AVAudioNodeTap::…RealtimeMessenger_Perform
```

4. Or **Product → Run** on the device in Xcode, tap the mic, and inspect the stopped thread in the debug navigator.

5. Live logs: Console.app → your iPhone → subsystem `dev.kekaflow.applebot`, category `voice`.
