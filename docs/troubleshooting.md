# Troubleshooting

## The app says the model is unavailable

| Banner | Cause | Fix |
|---|---|---|
| "This device does not support Apple Intelligence." | iPhone older than 15 Pro | Use a supported iPhone (15 Pro or newer), or enable an [external model](external-models.md) |
| "Turn on Apple Intelligence in Settings to chat." | Apple Intelligence is off | **Settings → Apple Intelligence & Siri** → turn on (tap **Open Settings** in the banner), or use an external model |
| "The on-device model is still downloading." | Model assets not ready yet | Stay on Wi-Fi and power; try again in a few minutes. Needs internet once, never for chatting |
| "Add your OpenAI/Anthropic API key." | External model switch is on without a key | Paste a key under **Settings → External model**, or turn the switch off |
| "The API key was rejected" | Wrong or revoked key | Paste a fresh key for the selected provider |
| Other | Unsupported region/language configuration | Check your device language and region support Apple Intelligence |

The send button stays disabled until the active model is ready.

## "The conversation is too long for the model."

On the on-device model the context window is small (about 4,000 tokens). Applebot compacts automatically and retries with tighter budgets, so this appears only when a single message plus the minimum context still does not fit. Shorten the question, reduce **Passages per answer** in Settings, or start a new chat. External models use a much larger window; if you still see this, the provider hit its own output or context limit.

## "I can't help with that one, but I'm happy to try if you put it another way."

Apple's safety guardrails refused. Rephrase the request. This is a model-level decision and is not retried.

## Answers ignore my documents

- If **Settings → Conversation style** is not *Neutral* and your message sounded distressed, Applebot skips the document search on purpose. See [emotional chat](emotional-chat.md).
- Check the chat toolbar menu: **Use my documents** must be on, and **Search scope** should include the document.
- The **Documents** tab must list the document; if import failed, an error appears under *Importing*.
- Open **Why this answer?** under a reply to see the search query and passages. If the right passage is missing, ask more specifically, or increase **Passages per answer**.
- If **Settings → Library → Embeddings** shows `hashing-…`, semantic matching is unavailable and only keyword overlap works well. On supported systems it should start with `nl-`.

## Attaching documents

| Problem | Fix |
|---|---|
| The **+** menu has no "From my library…" | Your library is empty. Import a file first |
| An attached file shows an error under the message box | Same causes as [import problems](#import-problems); tap the Documents tab for details |
| A chat stopped using a document I attached | The document was deleted from the library; attach it again |
| The **New Chat** button in the chat is greyed out | The current chat is still empty, so it is already a new conversation |
| I can't find an empty chat I started | Chats with no messages are discarded when you leave them |

## "I couldn't find that in your documents."

The retrieved passages did not contain the answer. Try different wording, use terms that appear in the document, or choose the specific document in the search scope.

## Import problems

| Message | Meaning |
|---|---|
| "No readable text was found in this document." | Empty file, or an image/scan with no recognizable text |
| "Files of type "x" are not supported yet." | Use PDF, text, Markdown, RTF, CSV, JSON, YAML, or an image |
| "the PDF is password protected" | Remove the password first |
| "Already in your library" | Identical content was imported before |

Large PDFs index in the background with a progress bar; keep the app open while it runs.

## Face ID lock

If the device has no passcode or biometrics, the lock cannot protect anything and the app unlocks automatically. Set a device passcode first.

## Connectors (accounts and live lookups)

Full table in [connectors](connectors.md#troubleshooting). The common ones:

| Problem | Fix |
|---|---|
| Settings says to add `GOOGLE_CLIENT_ID` | Create a Google OAuth client (iOS type, bundle ID `dev.kekaflow.applebot`) and run `GOOGLE_CLIENT_ID=... make project` |
| Settings says to add `BRAVE_API_KEY` | Get a Brave Search API key and run `BRAVE_API_KEY=... make project` |
| Google: "app has not completed verification" | Add your account as a **Test user** on the OAuth consent screen |
| "Gmail API has not been used in project …" | Enable the Gmail API in that Google Cloud project |
| "Your session expired. Reconnect…" | Google test-mode sign-ins last 7 days. Connect again |
| "Calendar access was denied" | Settings app → Applebot → Calendars → Full Access |
| "Couldn't reach Open-Meteo / Yahoo Finance / Brave Search" | Check the internet connection and try again |
| Applebot invents weather or a stock price | Turn on **Use in chats** for Weather / Stocks, leave documents off for that chat, and ask with a place or ticker |
| Applebot never uses a connector | The chat is using documents (use the notice's **Use … instead** button), or the connector is paused or not connected |

## Build and test issues

| Problem | Fix |
|---|---|
| `'v26' is unavailable` in Docker | Use a Swift image 6.2 or newer (`SWIFT_IMAGE=swift:6.2`) |
| Xcode: "A build only device cannot be used to run this target" | The destination is **Any iOS Device (arm64)**. Pick your iPhone or a simulator in the toolbar, or use `make device` / `make sim` |
| `make device`: "No connected iPhone found" | Connect by cable, unlock, tap Trust; check `make devices`. The state must be `connected` |
| `make device`: "Developer Mode is … on <phone>" | Enable Settings → Privacy & Security → Developer Mode, then restart the phone |
| `make device`: "Several devices are connected" | Choose one: `make device DEVICE="<name or UDID>"` |
| `make device`: "No signing team found" | Sign in to Xcode (Settings → Accounts) or run `make device TEAM_ID=XXXXXXXXXX` |
| App installs but will not open ("Untrusted Developer") | Settings → General → VPN & Device Management → your team → Trust |
| `make device`: launch fails | Unlock the phone and run it again |
| Xcode forgets the signing team after regenerating | Always generate with `make project`, which writes the team to `ios/Local.xcconfig` |
| `xcodegen: command not found` | `brew install xcodegen` |
| Xcode cannot find the project | Run `cd ios && xcodegen generate` (the `.xcodeproj` is generated, not committed) |
| UI tests cannot find the simulator | Pass an installed device name, for example `-destination 'platform=iOS Simulator,name=iPhone 17'` (`xcrun simctl list devices available`) |
| Docker tests are slow the first time | The first run pulls the Swift image and builds; later runs reuse the `swiftpm-build` volume |
| `tests-present` fails in CI | Add or update a test under `tests/`, or put `[skip-tests-check]` in the commit message for a pure refactor |
| `docs-check` fails | Fix the broken link it lists, link new docs from `README.md`, and add the new version to both `CHANGELOG.md` and `site/changelog.html` |
