# Development

## Prerequisites

- macOS with **Xcode 26** (iOS 26 SDK) for the app and Apple-only tests.
- **Docker** (Docker Desktop or compatible) for everything else.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.

## Docker Compose services

| Command | Purpose |
|---|---|
| `docker compose run --rm test` | Builds and runs all portable tests (LLMKit, RAGKit, retrieval eval) on Linux |
| `docker compose run --rm eval` | Retrieval-quality eval only (prints recall@k and MRR) |
| `docker compose run --rm docs-check` | Verifies docs, README links, site links, and changelog/site consistency |
| `docker compose up site` | Serves the static user guide at <http://localhost:8088> |

Sources are bind-mounted read-only, and SwiftPM build products live in a named volume (`swiftpm-build`), so nothing is built into your working tree and edits are picked up without rebuilding the image.

### Environment variables

Copy `.env.example` to `.env` to override. No secrets are required.

| Variable | Default | Meaning |
|---|---|---|
| `SWIFT_IMAGE` | `swift:6.2` | Swift toolchain image for the test runner |
| `SITE_PORT` | `8088` | Host port for the static site |
| `GOOGLE_CLIENT_ID` | empty | Google OAuth client ID (iOS type) that enables the Gmail connector. Read by `make project`, which writes it to the git-ignored `ios/Local.xcconfig`. A public identifier, not a secret. See [connectors](connectors.md) |
| `BRAVE_API_KEY` | empty | Brave Search API key that enables the Web search connector. Weather and Stocks need no key. Read by `make project` into `ios/Local.xcconfig`. Personal builds only; the key is compiled into the app. See [connectors](connectors.md) |

## Building and deploying the app (Makefile)

```bash
make sim        # build, install and launch on the iOS Simulator
make device     # build, sign, install and launch on your connected iPhone
make devices    # list iPhones/iPads this Mac can see
make test       # all portable tests in Docker
make project    # (re)generate the Xcode project only
make clean      # remove build output and the generated project
```

| Option | Example | Meaning |
|---|---|---|
| `SIM_NAME` | `make sim SIM_NAME="iPhone 17"` | Simulator to use (default `iPhone 17 Pro`) |
| `DEVICE` | `make device DEVICE="Pradeep's iPhone"` | Device name or UDID. Needed only when several are connected |
| `TEAM_ID` | `make device TEAM_ID=ABCDE12345` | Signing team. Default: detected from Xcode's signed-in account |
| `MOCK=1` | `make sim MOCK=1` | Launch with the mock engine (no Apple Intelligence needed), for UI demos |

Options can also be put in `.env` (see `.env.example`).

`make device` runs `xcodebuild` with automatic provisioning for your team, installs with `xcrun devicectl`, and launches the app. Before the first run:

1. Connect the iPhone by cable, unlock it, and tap **Trust**.
2. Enable **Settings → Privacy & Security → Developer Mode** (the phone restarts once).
3. Be signed in to Xcode (**Settings → Accounts**).
4. After the first install, if iOS says the developer is untrusted: **Settings → General → VPN & Device Management → your team → Trust**.

These targets run on the host because Xcode, the Simulator, and code signing cannot run in a container.

`make project` writes your team into the git-ignored `ios/Local.xcconfig`, which `ios/Signing.xcconfig` includes, so regenerating the project never loses your signing team.

### Using Xcode directly

```bash
make project && open ios/Applebot.xcodeproj
```

In the toolbar's destination menu, pick your iPhone or a simulator under **iOS Simulators**. **Any iOS Device (arm64)** is build-only and cannot run the app.

Bundle ID: `dev.kekaflow.applebot`.

Launch argument `-UITestMockEngine` swaps in `MockEngine`, in-memory storage and a mock calendar, which is what the UI tests use. `-UITestToolDemo` additionally scripts the first answer to propose adding a calendar event, to exercise tool calling and the approval sheet.

Command-line build:

```bash
cd ios && xcodebuild -project Applebot.xcodeproj -scheme Applebot \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Tests

All tests live in **`tests/`** (one folder, by rule):

| Path | What | Where it runs |
|---|---|---|
| `tests/LLMKitTests/` | Context budgeting, prompts, `ChatPipeline` (overflow retry, compaction, citations, tool calls), `ToolGuard` (approval, caps, trimming), external model streaming, Apple engine mapping and a live tool call | Docker (Linux); the Apple-only file runs on macOS |
| `tests/ConnectorKitTests/` | OAuth/PKCE, registry, Calendar, Gmail, Weather / Stocks / Web search (`LiveDataConnectorTests`) against a mock HTTP client, approval-gate behaviour; Keychain test runs on macOS | Docker (Linux); the Keychain file runs on macOS |
| `tests/RAGKitTests/` | Chunker, BM25, vectors, hybrid fusion/MMR, `KnowledgeBase`, retrieval eval, SQLite store, NaturalLanguage embedders | Docker (Linux); SQLite and NL tests run on macOS |
| `tests/UITests/` | XCUITest smoke tests against the mock engine | macOS CI / local simulator |
| `tests/fixtures/` | Sample documents and labelled retrieval questions | shared |
| `tests/ci/` | CI policy scripts (`check_tests_present.sh`, `check_docs.py`) | CI |

Why some tests need a Mac: `FoundationModels`, `NaturalLanguage`, `PDFKit`, `Vision`, `SQLite3`, and the iOS Simulator are not available in Linux containers. Those code paths are behind `#if canImport(...)`, and the macOS job runs them.

On a Mac you can run the Apple-only tests directly:

```bash
swift test --filter "SQLiteChunkStoreTests|AppleEmbedderTests|AppleFMEngineTests|KeychainTokenStoreTests"
```

`AppleFMEngineTests.testLiveGenerationWhenModelAvailable` makes a real model call when Apple Intelligence is available, and is skipped otherwise.

UI tests:

```bash
cd ios && xcodegen generate && xcodebuild test -project Applebot.xcodeproj -scheme Applebot \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

### Adding a test

Add it under `tests/` (the right sub-folder), and that is all: SwiftPM and XcodeGen already point there, and CI runs it on every push. For a new feature, update fixtures/eval cases when retrieval is affected.

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request:

1. **tests-present**: fails if `ios/Kit`, `ios/App`, or `backend/services` changed without any change under `tests/`. Add `[skip-tests-check]` to the commit message for pure refactors.
2. **unit-tests**: `docker compose run --rm --build test`.
3. **docs-check**: `docker compose run --rm docs-check`.
4. **apple-tests** (macOS): `swift test`, then the app build and UI tests on the simulator.

## Deployment and Helm

Applebot is an on-device app with **no server component**, so there is no Helm chart. If a backend service is ever added it must live under `backend/services/`, have a chart under `helm/` (with `values-dev.yaml` and `values-prod.yaml`), and CI should then bump `Chart.yaml` and the image tag on successful `main` builds.

## Code conventions

- Library code stays UI-free and portable; Apple-only APIs go behind `#if canImport(...)`.
- Public engine/embedder/store protocols are the seams for new implementations.
- Keep `LLMKit`/`RAGKit` free of third-party dependencies.
- Update `docs/`, `site/`, and `CHANGELOG.md` with any user-visible change.
