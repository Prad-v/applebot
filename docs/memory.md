# Cross-chat memory

Applebot can remember durable facts across conversations. Everything stays on this iPhone.

## Using it

1. Open **Settings → Memory → What Applebot remembers**.
2. Leave **Remember across chats** on (default).
3. Chat normally. After a turn, Applebot may store short facts (name, preferences, upcoming events, ongoing concerns).
4. In the list you can **pin**, **delete**, or turn memory off.

**Delete all chats and documents** also erases memories.

## What is stored

| Kept | Not kept |
|---|---|
| Names, relationships, job, city | One-off questions |
| Preferences (“prefer short replies”) | Passwords / secrets |
| Upcoming events and open worries | Full chat transcripts |

Facts are short third-person sentences such as `User's name is Sam`. At most about 60 facts are kept; pinned ones are preferred when the store is full.

## How it works

1. After each answer, an on-device extraction call (with a keyword heuristic fallback) proposes up to 3 new facts.
2. `MemoryBudget.merge` deduplicates and updates similar facts.
3. On the next send, `MemoryBudget.render` injects a small “Things you remember…” block into the system instructions (about 200 tokens).
4. Warm / coach personas are told to use facts naturally and not recite them as a list.

SwiftData model: `MemoryRecord` in the same encrypted `chats.store` as conversations. Portable logic: `ios/Kit/LLMKit/Memory.swift`. App store: `ios/App/Services/MemoryStore.swift`.

## Privacy

- No network. Facts never leave the device.
- You can review and delete every fact.
- Turning memory off stops both injection and extraction immediately.

## Tests

`tests/LLMKitTests/MemoryTests.swift` — merge, render, parse, heuristic, pipeline injection. Run with `docker compose run --rm test`.

## Troubleshooting

| Problem | Fix |
|---|---|
| New chats don't know my name | Confirm memory is on, chat once saying your name, then start a new chat |
| Wrong fact stored | Delete or edit via swipe in **What Applebot remembers** |
| Context feels tight | Memory uses a small token budget; document RAG still has priority when grounded |
EOF

