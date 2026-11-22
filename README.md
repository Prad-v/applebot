# Applebot

A private, **fully offline ChatGPT-style assistant for iPhone**. It runs Apple's on-device language model (Apple Intelligence, via the Foundation Models framework) and can answer questions about **your own documents** using on-device retrieval-augmented generation (RAG). No server and no account. Nothing leaves the phone unless you switch on a connector.

- **General chat** with streaming answers, saved conversations, search, pinning.
- **Chat with my documents**: import PDFs, text, Markdown, and photos (OCR). Answers cite their sources, and "Why this answer?" shows exactly what the model was given.
- **Emotional chat**: choose a warm companion or supportive coach style; Applebot reads your mood on-device and adapts its tone.
- **Long-term memory**: remembers durable facts across chats on-device; review them in Settings.
- **Personalization**: structured profile + confirmed prefs, ranked/expiring memory, optional morning brief, voice notes into a RAG pack, “write like me” style rewrite, and a local intent router. See [docs/personalization.md](docs/personalization.md).
- **Continuity**: document packs UI, gentle check-ins, on-device retrieval retune, family profiles with Face ID, encrypted `.applebotpack` backup, and local automations. See [docs/continuity.md](docs/continuity.md).
- **Voice**: speak to Applebot and hear replies; on-device recognition only (no cloud fallback).
- **Connectors**: **Gmail**, **Calendar**, **Reminders**, **Weather**, **Stocks** and **Web search**. Reads and live lookups run when you ask; drafts, events and reminder writes only after you approve the exact content. See [docs/connectors.md](docs/connectors.md).
- **External models (optional)**: in Settings, switch chats to **OpenAI** or **Anthropic** with your own API key. Off by default; keys stay in the Keychain. See [docs/external-models.md](docs/external-models.md).
- **Private by construction**: by default everything stays on the device, encrypted at rest, optional Face ID lock. With connectors and the external model off there are no network requests at all.
- Requires **iOS 26+** and an Apple Intelligence-capable iPhone (iPhone 15 Pro or newer) with Apple Intelligence turned on (unless you use an external model).

## Documentation

| Doc | What it covers |
|---|---|
| [docs/user-guide.md](docs/user-guide.md) | Using the app: chatting, importing documents, privacy settings |
| [docs/architecture.md](docs/architecture.md) | Components, data flow, context-window budgeting |
| [docs/connectors.md](docs/connectors.md) | Gmail, Calendar, Weather, Stocks and Web search: setup, approvals, security model, tool reference, adding a connector |
| [docs/external-models.md](docs/external-models.md) | Optional OpenAI / Anthropic chat backends: keys, privacy, OpenAI-compatible base URLs |
| [docs/emotional-chat.md](docs/emotional-chat.md) | Warm companion / coach styles, mood reading, safety notes |
| [docs/memory.md](docs/memory.md) | Cross-chat memory: what is stored, controls, privacy |
| [docs/personalization.md](docs/personalization.md) | Profile, ranked memory, morning brief, voice notes, style card, intent router |
| [docs/continuity.md](docs/continuity.md) | Packs UI, check-ins, retrieval retune, family profiles, vault, automations |
| [docs/voice.md](docs/voice.md) | Mic input, spoken replies, hands-free, on-device-only policy |
| [docs/rag.md](docs/rag.md) | Chunking, embeddings, hybrid retrieval, evaluation |
| [docs/development.md](docs/development.md) | Building, Docker Compose workflow, tests, CI, environment variables |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common problems and fixes |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |

A static copy of the user guide lives in [site/](site/index.html). Preview it with `docker compose up site` and open <http://localhost:8088>.

## Quick start

```bash
# 1. Run all portable tests (no host dependencies) in Docker
docker compose run --rm test

# 2. Deploy
brew install xcodegen          # one-time
make sim                       # run on the iOS Simulator
make device                    # run on your connected iPhone (cable, unlocked, Developer Mode on)
```

Run on a physical iPhone 15 Pro or newer for real Apple Intelligence answers. The simulator uses your Mac's Apple Intelligence model when available. `make sim MOCK=1` exercises the UI without any model. See [docs/development.md](docs/development.md) for options and first-run steps.

## Repository layout

```
Package.swift            Root Swift package (LLMKit + RAGKit + ConnectorKit) so tests can live in tests/
ios/
  App/                   SwiftUI app (chats, documents, settings)
  Kit/LLMKit/            Engine protocol, Apple + optional OpenAI/Anthropic engines, context budgeting, chat pipeline
  Kit/RAGKit/            Chunker, embeddings, hybrid index, SQLite store, extractors, evaluator
  Kit/ConnectorKit/      Connector protocol and registry, OAuth (PKCE), Gmail, Calendar, Weather, Stocks, Web search
  project.yml            XcodeGen spec (the .xcodeproj is generated, not committed)
tests/                   The single test folder: unit, retrieval eval, UI smoke tests, CI scripts
docs/                    Markdown documentation
site/                    Static user-guide website
tools/                   One-off developer tools (icon generator)
Makefile                 make sim / make device / make test
docker-compose.yml       test, eval, docs-check, site services
.github/workflows/       CI: tests in Docker, plus a macOS job for Apple-only code and UI tests
```

## Project rules

- All tests live in `tests/` and run in CI on every push. CI fails if source changes land without test changes.
- Local testing uses Docker Compose. The only host-side steps are the ones that need Xcode (building the app, Apple-framework tests, the simulator).
- User-facing changes update `docs/`, `site/`, and `CHANGELOG.md`; CI checks they stay consistent.
- There is no backend: connectors talk from the phone straight to Google. If a backend is ever added it goes in `backend/services/` with a Helm chart in `helm/`.
