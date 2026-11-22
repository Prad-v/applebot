# Continuity, packs, family profiles, vault, automations

This wave builds on [personalization](personalization.md): first-class document packs, gentle check-ins, on-device retrieval retune, family profiles with Face ID, encrypted backup, and local automations.

Everything stays on this iPhone.

## Document packs

**Documents** tab:

- Filter by pack (All / Unfiled / named packs)
- Create a pack, then swipe or long-press a document → **Move to pack**
- Voice notes still land in **Voice notes**

Packs are stored on each `DocumentRecord` (with legacy `"Pack / Title"` titles still understood). New imports are tagged with the active family profile.

## Gentle check-ins

**Settings → Personal → Gentle check-ins** (off by default).

Every few days, when you unlock or foreground the app, Applebot may offer one soft prompt about an open loop or near-term event from memory. **Let's talk** opens a new chat with that prompt. Nothing is sent off-device.

The morning brief can also list incomplete **Reminders** (when Reminders access is granted), alongside Calendar and memory open loops.

## Retrieval retune

On answers that used your documents, tap **Helpful?** thumbs. Applebot nudges hybrid vector vs keyword weights for the **active family profile**. Settings shows the current weights. No cloud training.

## Family profiles + Face ID

**Settings → Personal → Family profile**

- Add profiles (e.g. you + a partner)
- Switch with Face ID / passcode when the target (or current) profile requires it
- Each profile scopes: personal profile, memories, style card, brief, check-ins, automations, retrieval weights, and document ownership
- Chats are filtered to the active profile

## Encrypted backup & restore

**Settings → Personal → Backup & restore**

1. Choose a password (6+ characters)
2. Optionally include document text
3. Export an `.applebotpack` (AES-GCM, password-derived key)
4. Import into the **active** family profile with the same password

The file never leaves the device unless you share it yourself.

## Local automations

**Settings → Personal → Automations**

Recipes such as **Every Sunday · week plan**. On unlock, if a recipe is due, Applebot asks before running. Confirming opens a chat with the recipe prompt. No background cloud jobs.

## Developer map

| Piece | Location |
|---|---|
| Packs | `DocumentRecord.pack`, `DocumentPack`, Documents UI |
| Check-ins | `CheckIn.swift`, `CheckInController` |
| Retrieval tune | `RetrievalTuner.swift`, `RetrievalTunerStore`, thumbs on `MessageBubble` |
| Family | `FamilyProfile.swift`, `FamilyProfileStore` |
| Vault | `PersonalVault.swift`, `PersonalVaultCrypto` |
| Automations | `Automation.swift`, `AutomationStore` |

Tests: `tests/LLMKitTests/ContinuityTests.swift`, `tests/RAGKitTests/DocumentPackTests.swift`.

```bash
docker compose run --rm test
```
