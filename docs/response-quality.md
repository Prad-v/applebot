# Response quality

How Applebot keeps on-device answers useful inside the ~4k token window: lean instructions, task-aware sampling, and a grounded citation check.

## Instruction modes

`InstructionMode` selects which system-prompt blocks load for the turn:

| Mode | When | What loads |
|---|---|---|
| `conversational` | Open chat | Full companion persona + mood/cue (Warm/Coach) + memories |
| `emotional` | Distress or “how are you?” | Full companion persona + mood/cue; tools only if still offered |
| `grounded` | Document RAG | **Compact** persona + grounding rules first + memories (no long companion examples) |
| `tools` | Connector / live data | Compact persona + tool safety + date + memories |

Warm and Coach keep a short `compactPersona` for grounded/tool turns so passages and tool results get more of the window.

## Sampling and length

| Situation | Temperature (approx.) | Max response tokens |
|---|---|---|
| Grounded / documents | 0.2 (Neutral) / 0.35 (Warm, Coach) | 550 |
| Emotional companion | 0.75 / 0.7 | 220 |
| Open Warm / Coach chat | 0.75 / 0.7 | 320 |
| Neutral chat | engine default | 480 |

`LLMRequest.maximumResponseTokens` is passed to Apple Foundation Models and to OpenAI / Anthropic when an external model is on.

## Grounded verify + one retry

After a document-grounded answer:

1. If the reply already contains the not-found phrase, accept it.
2. If there were passages but no `[n]` citations (or context was empty and the model invented an answer), regenerate **once** with `PromptBuilder.groundingRetryNote`.
3. Citations are still parsed for source chips and **Why this answer?**.

## Intent router (local)

`IntentRouter` stays keyword-based (no extra model call on the hot path). Factual starters and document phrasing (`explain…`, `what's the…`, `in my handbook`, …) prefer `.documents` when **Use my documents** is on.

## Developer reference

| Type / API | Role |
|---|---|
| `InstructionMode` | Lean vs full instruction assembly |
| `ChatTone.compactPersona` | Short Warm/Coach for RAG/tools |
| `ChatTone.samplingTemperature(grounded:intent:)` | Task-aware temperature |
| `ChatTone.maximumResponseTokens(grounded:intent:)` | Soft answer length cap |
| `PromptBuilder.needsGroundingRetry` | Citation / empty-context check |
| `ChatPipeline` | Applies mode, options, and one verify retry |

Tests: `tests/LLMKitTests/PromptBuilderTests.swift`, `ChatPipelineTests.swift`, `CompanionTests.swift`. Run with `docker compose run --rm test`.

## Related

- [architecture.md](architecture.md) — full turn pipeline and context budget
- [emotional-chat.md](emotional-chat.md) — tones and mood reading
- [rag.md](rag.md) — retrieval and grounding rules
- [personalization.md](personalization.md) — intent router overview
