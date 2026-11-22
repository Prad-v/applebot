# Personalization (on-device)

Applebot builds a private personal context on this iPhone: a structured profile, ranked memories with expiry, an optional morning brief, voice notes into a document pack, a “write like me” style card, and a local intent router that keeps the ~4k-token window useful.

Nothing here leaves the device (unless you later send a chat through an external model you enabled).

## Your profile

**Settings → Personal → Your profile**

| Field | Purpose |
|---|---|
| Name, city, roles | Compact identity lines in every prompt |
| Reply style | Concise / detailed / bullets / balanced |
| Boundaries | Hard rules (“no work talk after 9pm”) |
| Confirmed preferences | Only after you tap **Keep** on a proposal |

Preferences learned from chat are **proposed**, not silent. Confirm or dismiss them in the profile screen.

The profile block is capped at about **80 tokens**. Ranked memory facts use the rest of the shared **200-token** personal-context budget (`PersonalContextBudget`).

## Typed / ranked memory + expiry

Facts still live under **Settings → What Applebot remembers**, with richer types:

`person`, `preference`, `event`, `openLoop`, `place`, `project`, `other`

- **Ranking**: pinned → category weight → confidence → recency → soon-to-expire boost.
- **Expiry**: events (~14 days) and open loops (~45 days) drop from prompts (and the store) unless pinned.
- **lastUsedAt**: facts injected into a prompt stay warmer in future ranking.

Preferences extracted from chat go to the profile confirmation queue instead of the fact list.

## Morning / unlock brief

**Settings → Personal → Morning brief on unlock** (off by default).

Once per calendar day, when the app becomes active or you unlock with Face ID, Applebot builds a brief from:

1. Today’s **Calendar** events (if Calendar is connected)
2. Ranked **open loops** / near-term events from memory
3. Your profile name for the greeting

Dismiss the sheet to continue. No network; Calendar data stays on device.

## Voice note → RAG pack

In a chat, **+ → Voice note…**:

1. Speak; recognition stays on-device.
2. Review the structured title / bullets.
3. Save into the **Voice notes** pack (`Voice notes / Title` in the document library).

The note is indexed like any other document and can be attached to the chat. Pack naming uses a title prefix (`DocumentPack`); no cloud sync.

## Write like me (style card)

**Settings → Personal → Write like me**

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

This keeps airplane-mode chats snappy inside the on-device context window.

## Developer map

| Piece | Location |
|---|---|
| Profile + budget | `ios/Kit/LLMKit/PersonalProfile.swift` |
| Ranked memory | `ios/Kit/LLMKit/Memory.swift` |
| Intent router | `ios/Kit/LLMKit/IntentRouter.swift` |
| Style card | `ios/Kit/LLMKit/StyleCard.swift` |
| Voice notes | `ios/Kit/LLMKit/VoiceNote.swift` |
| Daily brief | `ios/Kit/LLMKit/DailyBrief.swift` |
| Document packs | `ios/Kit/RAGKit/DocumentPack.swift` |
| Pipeline wiring | `ios/Kit/LLMKit/ChatPipeline.swift` |
| App stores / UI | `PersonalProfileStore`, `StyleCardStore`, `DailyBriefController`, Settings / sheets |

Tests: `tests/LLMKitTests/PersonalizationTests.swift`, `tests/RAGKitTests/DocumentPackTests.swift`.

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
