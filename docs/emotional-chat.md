# Emotional chat

Applebot can talk like a warm companion or a supportive coach instead of a concise assistant. It also reads the mood of each message, on the device, and adapts its reply. Nothing is sent anywhere.

## Using it

1. Open **Settings → Conversation style**.
2. Pick a style:

| Style | Behaviour |
|---|---|
| **Warm companion** (default) | Kind and unhurried. Answers "how are you?" in character, acknowledges feelings first, asks at most one gentle question. |
| **Neutral** | The original concise, factual assistant. No mood reading. |
| **Supportive coach** | Encouraging and practical. One sentence of empathy, then one small concrete next step. |

3. Start a chat. In a warm or coach style the empty chat asks "How are you feeling today?" and offers conversation starters.

The style applies to the next message you send, in every chat.

## What happens to each message

1. **Companion cue.** Short check-ins like "How are you feeling today?" are detected so Applebot answers in the first person with a brief mood, instead of saying it has no feelings.
2. **Mood reading.** The message is scanned on the device for the main emotion (`sadness`, `anxiety`, `anger`, `joy`, or `neutral`) and how strong it is (1 to 5). Apple's on-device sentiment model is used as a fallback for messages with no obvious emotion words.
3. **Tone guidance.** The reading adds a short instruction to the model, for example "The user seems anxious. Be calm and reassuring." Strong feelings also ask for shorter replies.
4. **Documents step aside.** If you are clearly struggling (sadness, anxiety or anger at strength 3 or more), or you are checking in on Applebot, the document search is skipped for that message so you get a conversation. Calm factual questions still use your documents.

Neutral style never reads mood and behaves exactly as before.

## Safety

- The persona tells the model it is not a therapist, must not diagnose, and should encourage contacting emergency services or a crisis line if you mention harming yourself or being in danger.
- If Apple's guardrails decline a message, Applebot now says "I can't help with that one, but I'm happy to try if you put it another way."
- Applebot is not a substitute for professional help. If you are in crisis, contact your local emergency number or a crisis line.

## Developer reference

All logic lives in `ios/Kit/LLMKit/Companion.swift` and is portable (tested on Linux in Docker).

| Type | Role |
|---|---|
| `ChatTone` | `neutral`, `warm`, `coach`: display text and persona |
| `Emotion`, `EmotionReading` | Detected feeling and intensity; `guidance` text and `needsSupport` flag |
| `CompanionCue` | Detects "how are you?" / "do you feel…?" and injects first-person reply guidance |
| `EmotionDetecting` | Protocol for detectors |
| `LexiconEmotionDetector` | Keyword detector with negation, phrases and intensity boosts (all platforms) |
| `SentimentEmotionDetector` | Lexicon plus Apple `NaturalLanguage` sentiment fallback (Apple platforms) |

```swift
let pipeline = ChatPipeline(
    engine: engine,
    prompts: PromptBuilder(tone: .warm),        // tone selects the persona
    emotionDetector: SentimentEmotionDetector() // optional; defaults to LexiconEmotionDetector
)
// ChatResult.emotion holds the reading for the user's message.
```

The tone is stored in `UserDefaults` under the key `chatTone` (`AppEnvironment.Keys.chatTone`), defaulting to **Warm companion**. Warm and coach styles also raise the on-device sampling temperature slightly so replies feel less flat. There are no network calls and no new environment variables.

Tests: `tests/LLMKitTests/CompanionTests.swift`. Run them with `docker compose run --rm test`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Replies still sound formal | Check **Settings → Conversation style** is not *Neutral* |
| The bot ignored my documents | You were detected as distressed, so retrieval was skipped. Ask again in a calmer, specific way, or switch to *Neutral* |
| The mood seems wrong | Detection is keyword based and deliberately simple. Say how you feel in plain words ("I feel anxious") |
| "I can't help with that one…" | Apple's safety guardrails declined. Rephrase the message |

## Not yet included

Crisis-phrase detection with a fixed helpline response, long-term personal memory, mood-tinted bubbles, haptics, and daily check-ins are planned follow-ups.
