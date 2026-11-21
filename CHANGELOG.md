# Changelog

All notable changes to Applebot are documented here. Versions follow semantic versioning.

## 0.3.0

### Added
- **Connectors**: Applebot can now use **Gmail** and your **Calendar** when you ask (Settings → Connected services → Connectors). Off until you connect them, and each can be paused without signing out.
- **Calendar**: ask about your schedule, and add events. Reads stay on the iPhone.
- **Gmail**: search and read your email, and save a reply draft. Applebot never sends email.
- **Approvals**: anything that changes something (saving a draft, adding an event) shows the exact content first and only happens if you approve. Declining, dismissing the sheet, or leaving the chat all mean no.
- Replies that used a connector say which one ("Searching Gmail").
- A notice in chats that search your documents explains that connectors are paused, with a one-tap **Use Gmail and Calendar instead**.
- New `ConnectorKit` library (OAuth 2.0 with PKCE, Keychain token storage, connector registry) and tool calling in `LLMKit` (`ToolSpec`, `ToolGuard`, Foundation Models adapter).
- Documentation: [docs/connectors.md](docs/connectors.md). New build setting `GOOGLE_CLIENT_ID` for Gmail.

### Changed
- "Network: Not used" in Settings now reads "Only for connectors you turned on" while a Gmail-style connector is on. With connectors off the app still makes no network requests.
- "Delete all chats and documents" also signs out of connected accounts and removes their tokens.

### Security
- Email content is treated as untrusted data; there is no tool that sends, deletes or forwards mail, so a malicious email cannot make Applebot send anything.

## 0.2.0

### Added
- **New chat from inside a conversation**: a compose button in the chat toolbar starts a brand new, empty conversation (no history, no summary, search scope reset to all documents). Back returns to the chat list.
- **Attach documents to a chat** with the **+** button next to the message box: Files, Photos (on-device OCR), Paste text, or pick from your library.
- Attached documents show as chips above the message box. Tap to change the scope, or tap the x to remove one.

### Changed
- Attaching documents to a chat narrows that chat's search to the attached documents. Removing the last one returns to "all documents".
- Empty chats that never received a message are no longer saved or listed.
- Documents deleted from the library are dropped from any chat's scope automatically.

## 0.2.0

### Added
- Emotional chat: **Settings → Conversation style** with Neutral, Warm companion and Supportive coach.
- On-device mood reading (sadness, anxiety, anger, joy) that adapts the reply's tone and length.
- Distressed messages skip the document search so Applebot talks instead of answering "not found".
- Emotion-aware empty chat ("How are you feeling today?") with conversation starters.

### Changed
- When Apple's safety guardrails decline a message, Applebot now responds kindly and suggests rephrasing.

## 0.1.0

First working version.

### Added
- Offline chat with Apple's on-device language model (Foundation Models), with streaming answers.
- Saved conversations with search, pinning, and swipe-to-delete.
- Rolling conversation summary so long chats survive the model's small context window.
- Private document library: import PDF, text, Markdown, RTF, and images (on-device OCR), or paste text.
- Hybrid retrieval (semantic vectors + BM25 keywords) with MMR de-duplication.
- Grounded answers with source citations and a "Why this answer?" sheet.
- Per-chat search scope (all documents or a chosen subset).
- Optional Face ID / passcode lock, encrypted-at-rest storage, and a "delete everything" action.
- Availability banner explaining when Apple Intelligence is unavailable.
- Retrieval-quality evaluation (recall@k, MRR) and a CI gate on it.
