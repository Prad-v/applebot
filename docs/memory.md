# Cross-chat memory

Applebot can remember durable facts across conversations. Everything stays on this iPhone. Profile, preference confirmation, ranking and expiry are covered in [personalization](personalization.md).

## Using it

1. Open **Settings → Personal → What Applebot remembers**.
2. Leave **Remember across chats** on (default).
3. Chat normally. After a turn, Applebot may store short facts (name, upcoming events, ongoing concerns, places, projects).
4. In the list you can **pin**, **delete**, or turn memory off. Preference proposals appear under **Your profile** for confirmation.

**Delete all chats and documents** also erases memories and the personal profile.

## What is stored

| Kept | Not kept |
|---|---|
| Names, relationships, job, city | One-off questions |
| Upcoming events and open worries (with expiry) | Passwords / secrets |
| Places and projects | Full chat transcripts |
| Preference *proposals* (confirmed in profile) | Silent preference injection |

Facts are short third-person sentences such as `User's name is Sam`. Types: `person`, `preference`, `event`, `openLoop`, `place`, `project`, `other`. At most about 60 facts are kept; ranking prefers pinned, high-confidence, and recently used facts. Events and open loops expire unless pinned.

## How it works

1. After each answer, an on-device extraction call (with a keyword heuristic fallback) proposes up to 3 new facts.
2. Preference facts go to the profile confirmation queue; identity facts also update **Your profile**.
3. `MemoryBudget.merge` deduplicates, sets default expiry, and ranks.
4. On the next send, `PersonalContextBudget.render` injects profile (~80 tokens) + ranked facts (remainder of ~200 tokens).
5. Warm / coach personas are told to use facts naturally and not recite them as a list.

SwiftData model: `MemoryRecord` in the same encrypted `chats.store` as conversations. Portable logic: `ios/Kit/LLMKit/Memory.swift`. App store: `ios/App/Services/MemoryStore.swift`.

## Privacy

- No network. Facts never leave the device.
- You can review and delete every fact.
- Turning memory off stops both injection and extraction immediately.

## Tests

`tests/LLMKitTests/MemoryTests.swift`, `tests/LLMKitTests/PersonalizationTests.swift`. Run with `docker compose run --rm test`.

## Troubleshooting

| Problem | Fix |
|---|---|
| New chats don't know my name | Confirm memory is on, chat once saying your name, then start a new chat — or set **Your profile** |
| Wrong fact stored | Delete via swipe in **What Applebot remembers** |
| Preference never applied | Confirm it under **Your profile** |
| Context feels tight | Personal context shares ~200 tokens; document RAG still has priority when grounded |

