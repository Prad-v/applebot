# Personalization (on-device)

Applebot builds a private personal context on this iPhone: a structured profile, ranked memories with expiry, a **behavioral patterns** card (routines / interests / stress), an optional morning brief, voice notes into a document pack, a “write like me” style card, and a local intent router that keeps the ~4k-token window useful.

Nothing here leaves the device (unless you later send a chat through an external model you enabled).

## Behavioral patterns (user twin card)

**You → Personal → Behavioral patterns**

Applebot does **not** fine-tune a model on your life. It builds a compact on-device summary from:

| Signal | Source | Example prompt line |
|---|---|---|
| Sleep duration | Apple Health week trend | Typical sleep: 7.2h / night |
| Exercise / steps | Health workouts + steps | Exercise: ~3.5 days / week |
| Work / office window | Today’s Calendar timed events | Workday calendar window: 09:00–18:00 |
| Interests / search topics | Chat questions + tools | Often asks about: Travel, Fitness |
| Travel affinity | Travel keywords in chat / search | Travel interest: high |
| Stress behaviour | Distressed chat tone (± short sleep) | Prefer calm, short replies |
| Spending hints | Money / shopping language in chat | Often discusses budgets or purchases |

After a few days of Health data and chatting, the card is injected into every prompt (~**100 tokens**, separate from the profile+memory **200**). Toggle it off anytime; **Refresh from Health & Calendar** updates routines without waiting for unlock.

This is the foundation for a “behaves like you” companion: summarized patterns in the prompt, not continuous raw GPS/IMU streaming (see [on-device-enhancements](on-device-enhancements.md)).

## Your profile

**You → Personal → Your profile**

| Field | Purpose |
|---|---|
| Name, city, roles | Compact identity lines in every prompt |
| Reply style | Concise / detailed / bullets / balanced |
| Boundaries | Hard rules (“no work talk after 9pm”) |
| Confirmed preferences | Only after you tap **Keep** on a proposal |

Preferences learned from chat are **proposed**, not silent. Confirm or dismiss them in the profile screen.

The profile block is capped at about **80 tokens**. Ranked memory facts use the rest of the shared **200-token** personal-context budget (`PersonalContextBudget`).

## Typed / ranked memory + expiry

Facts still live under **You → What Applebot remembers**, with richer types:

`person`, `preference`, `event`, `openLoop`, `place`, `project`, `other`

- **Ranking**: pinned → category weight → confidence → recency → soon-to-expire boost.
- **Expiry**: events (~14 days) and open loops (~45 days) drop from prompts (and the store) unless pinned.
- **lastUsedAt**: facts injected into a prompt stay warmer in future ranking.

Preferences extracted from chat go to the profile confirmation queue instead of the fact list.

## Morning / unlock brief

**You → Personal → Morning brief on unlock** (off by default).

Once per calendar day, when the app becomes active or you unlock with Face ID, Applebot builds a brief from:

1. Today’s **Calendar** events (if Calendar is connected)
2. Ranked **open loops** / near-term events from memory
3. Optional **Health** and **Markets** lines when those tabs have data
4. Your profile name for the greeting

Dismiss the sheet to continue. Calendar data stays on device; market lines use cached or freshly refreshed Stocks quotes when that connector is on (see [stocks](stocks.md)).

## Voice note → RAG pack

In a chat, **+ → Voice note…**:

1. Speak; recognition stays on-device.
2. Review the structured title / bullets.
3. Save into the **Voice notes** pack (`Voice notes / Title` in the document library).

The note is indexed like any other document and can be attached to the chat. Pack naming uses a title prefix (`DocumentPack`); no cloud sync.

## Write like me (style card)

**You → Personal → Write like me**

1. Turn on **Enable style rewrite**.
2. Paste up to three short samples of your writing and optional traits.
3. In chat, send `rewrite this: …` (or similar). The local intent router takes the rewrite path: no RAG, no tools, style-card instructions only.

This is the on-device “SKU” for personal voice without a cloud fine-tune.

## Local intent router

Before retrieval or tools, `IntentRouter` classifies the message (no model call):

| Intent | Effect |
|---|---|
| `emotional` | Skip documents; talk |
| `rewrite` | Style-card path |
| `calendar` / `email` / `liveData` | Prefer tools; skip RAG |
| `documents` | Run retrieval when “Use my documents” is on |
| `chat` | Skip RAG and tools |

This keeps airplane-mode chats snappy inside the on-device context window. Instruction assembly and sampling then follow [response-quality.md](response-quality.md) so companion examples do not crowd out passages or tool results.

## Developer map

| Piece | Location |
|---|---|
| Profile + budget | `ios/Kit/LLMKit/PersonalProfile.swift` |
| Behavioral twin card | `ios/Kit/LLMKit/BehavioralProfile.swift` |
| Ranked memory | `ios/Kit/LLMKit/Memory.swift` |
| Intent router | `ios/Kit/LLMKit/IntentRouter.swift` |
| Style card | `ios/Kit/LLMKit/StyleCard.swift` |
| Voice notes | `ios/Kit/LLMKit/VoiceNote.swift` |
| Daily brief | `ios/Kit/LLMKit/DailyBrief.swift` |
| Document packs | `ios/Kit/RAGKit/DocumentPack.swift` |
| Pipeline wiring | `ios/Kit/LLMKit/ChatPipeline.swift` |
| App stores / UI | `PersonalProfileStore`, `BehavioralProfileStore`, `StyleCardStore`, `DailyBriefController`, Settings / sheets |

Tests: `tests/LLMKitTests/PersonalizationTests.swift`, `tests/LLMKitTests/BehavioralProfileTests.swift`, `tests/RAGKitTests/DocumentPackTests.swift`.

```bash
docker compose run --rm test
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Morning brief never appears | Turn it on; unlock or foreground the app; it shows at most once per day |
| Brief has no events | Connect Calendar under Connectors and grant access |
| Rewrite ignores my voice | Enable the style card and add at least one sample or traits |
| Preference never stuck | Confirm it under **Your profile → Confirm preferences** |
| Old events still show | Unpin them, or wait for expiry purge on next Memories visit |
| Behavioral card empty | Connect Health and/or Calendar; chat for a few days; tap **Refresh from Health & Calendar** |
| Patterns feel wrong | Toggle off, or **Clear behavioral data** and rebuild |
