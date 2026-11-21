# Voice conversation

Talk to Applebot and hear replies. Speech recognition and spoken answers are designed to stay **on this iPhone**.

## Using it

1. In a chat, tap the **mic** next to the message field. Speak, then tap the mic again (or wait for end-of-utterance).
2. The transcript is sent like a typed message.
3. With **Settings → Voice → Speak replies** on (default), Applebot reads the answer aloud.
4. Turn on **Hands-free conversation** to listen again automatically after each spoken reply. Tap **Stop** or leave the chat to end the loop.

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
| Hands-free conversation | Off | After speaking, start listening again |
| On-device speech | Read-only | Whether the current language supports on-device recognition |

## Implementation

- `ios/App/Services/VoiceController.swift` — listening, speaking, hands-free resume
- Mic + status line in `ChatView`
- Stop cancels generation, listening and speech together

## Limits

- Accents and noisy rooms affect recognition quality.
- Long answers are spoken in full; tap Stop to interrupt.
- Hands-free can pick up TV or other voices; use it in a quiet place.

## Troubleshooting

| Problem | Fix |
|---|---|
| Mic does nothing / “unavailable” | Your locale may lack on-device recognition. Type instead, or check iOS language settings |
| “Microphone is not ready” on Simulator | Enable **I/O → Audio Input** in the Simulator menu, or test on a physical iPhone |
| App used to crash on mic tap | Fixed: Applebot now checks the mic format and permissions before listening |
| No permission sheet | Settings → Applebot → Microphone / Speech Recognition |
| No spoken reply | Enable **Speak replies**; confirm Silent Mode / volume |
| Keeps listening forever | Turn off Hands-free, or tap Stop |
EOF
