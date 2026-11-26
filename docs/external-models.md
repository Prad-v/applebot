# External models (OpenAI and Anthropic)

By default Applebot answers with Apple's on-device language model. In **You → External model** you can switch chats to **OpenAI** or **Anthropic** using your own API key.

## What it does

1. Choose a provider (OpenAI or Anthropic).
2. Paste an API key (stored only in this iPhone's Keychain).
3. Optionally set a model name or a custom base URL.
4. Turn on **Use external model**.

While the switch is on and the provider is ready, every chat message (including document passages used for grounded answers, and connector tool traffic that goes through the model) is sent to that provider over HTTPS. Turn the switch off to return to Apple Intelligence on the device.

## Providers

| Provider | Default model | Default base URL | Key header |
|---|---|---|---|
| OpenAI | `gpt-4o-mini` | `https://api.openai.com/v1` | `Authorization: Bearer …` |
| Anthropic | `claude-sonnet-5-5` | `https://api.anthropic.com/v1` | `x-api-key` |

The model field is free text. Suggested names are shortcuts only; any model your account can call works.

### OpenAI-compatible servers

OpenAI mode speaks the Chat Completions API (`POST …/chat/completions` with SSE). Set **Advanced → Base URL** to point at a proxy or a local server (for example Ollama on your Mac). Plain `http://` is allowed only for localhost and local-network addresses so the API key is never sent in the clear over the public internet.

## Privacy

- API keys never leave the Keychain on this device (no iCloud Keychain sync).
- With the switch **off**, behaviour is unchanged: chats stay on-device.
- With the switch **on**, prompts and answers go to the provider you chose. Document originals still stay on the phone; only the text included in each prompt is sent.
- Connectors (Gmail, Calendar, …) still talk directly to their own services. The external model only receives what the chat pipeline already sends the on-device model.

## Connectors and tools

External engines support the same connector tools as the on-device model. The engine runs a short tool loop: stream → run tools (with the usual approval sheet for writes) → stream again, until the model finishes or a round limit is hit.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Banner: "Add your … API key" | Paste a key, or turn the external switch off |
| "The API key was rejected" | Check the key and that it belongs to the selected provider |
| Rate-limit error | Wait and retry; use a smaller/cheaper model |
| Custom base URL rejected | Use `https://`, or `http://` only for localhost / LAN |
| Want on-device again | You → External model → turn **Use external model** off |

## Implementation notes

- Config and the enable flag live in `ExternalModelStore` (`UserDefaults` + `SecretStore`).
- `ExternalEngine` implements `ToolCallingEngine` and uses `StreamingTransport` so unit tests never hit the network.
- `AppEnvironment.activeEngine()` returns an external engine when the switch is on and the config is ready; otherwise the on-device (or mock) engine.
- External chats use a larger `ContextManager` window (128k tokens) than the on-device ~4k window.
