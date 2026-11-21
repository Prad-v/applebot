# User guide

Applebot is a chat assistant that runs entirely on your iPhone. It works in airplane mode and never sends your messages or documents anywhere.

## Requirements

- iOS 26 or later.
- An iPhone with Apple Intelligence: iPhone 15 Pro, 15 Pro Max, or any iPhone 16 or newer.
- Apple Intelligence turned on in **Settings → Apple Intelligence & Siri**. The first time, iOS downloads the model; Applebot shows a banner until it is ready.

## Chatting

1. Open the **Chats** tab and tap the compose button (or **Start chatting**). Each new chat is a brand new conversation: it has no memory of other chats.
2. Type a message and tap the arrow. The answer streams in as it is generated. Tap the stop button to interrupt.
3. Long-press an answer to **copy** or **share** it.
4. Swipe a chat right to **pin** it, left (or use Edit) to **delete** it. Use the search field to find chats by title or content.

### Start a new conversation

Tap the compose button in the chat's top bar to start a fresh conversation at any time. Your current chat is saved in the list, and the new one starts empty: no history, no summary, and the document search reset to all documents. The button is greyed out while the current chat is still empty. A chat that never receives a message is not saved.

Long conversations are handled automatically: older messages are condensed into a short summary so the model can keep going within its small context window.

## Conversation style and emotional chat

In **Settings → Conversation style**, choose how Applebot talks:

- **Neutral** (default): concise and factual.
- **Warm companion**: kind and attentive. It listens first and acknowledges how you feel.
- **Supportive coach**: encouraging and practical, with one small next step.

In the warm and coach styles, Applebot reads the mood of each message on your iPhone and adapts. If you are clearly upset it skips the document search so it can simply talk with you. Empty chats ask "How are you feeling today?". Applebot is not a therapist; if you are in crisis, contact your local emergency number or a crisis line. See [emotional chat](emotional-chat.md) for details.

## Connectors: Gmail and Calendar

Connectors let Applebot look things up in your accounts when you ask, and propose actions that you approve first. They are **off until you connect them**.

1. Open **Settings → Connected services → Connectors**.
2. Tap **Connect Calendar** or **Connect Gmail** and follow the prompts. Keep **Use in chats** on, or switch it off to pause a connector.
3. Ask in a chat, for example "What's on my calendar tomorrow?", "Any emails from Alice this week?", "Reply to Alice's lunch email saying yes", or "Add lunch with Sam tomorrow at 12:30".

Reading happens straight away. Anything that **changes** something (saving a Gmail draft, adding a calendar event) shows a sheet with the exact content, and only happens if you tap the green button. **Don't allow**, dismissing the sheet, or leaving the chat all mean no. Applebot never sends email: it can only save a draft for you to review and send yourself.

Connectors work in chats that are **not** searching your documents. If you have documents in your library, a notice in the chat offers **Use Gmail and Calendar instead**. Gmail needs a one-time Google setup; see [connectors](connectors.md).

## Chat with your documents

### Add documents
1. Open the **Documents** tab and tap **+**.
2. Choose **Import files** (PDF, text, Markdown, RTF, CSV, JSON, YAML, or images such as photos of paper documents) or **Paste text**.
3. Applebot reads the text, splits it into passages, and indexes them on the device. A progress bar shows indexing. Scanned PDFs and images use on-device text recognition (OCR).

Re-importing the same content is detected and skipped. Originals are **not** copied into the app; only extracted text and search vectors are stored.

### Attach documents to a chat

Tap the **+** button next to the message box:

| Option | What it does |
|---|---|
| **Files…** | Pick PDFs, text, Markdown, and other supported files |
| **Photos…** | Pick photos or screenshots of documents; text is read with on-device OCR |
| **Paste text…** | Add a note by pasting text |
| **From my library…** | Choose documents you already imported |

Imported documents are added to your library and **attached to this chat**. They appear as chips above the message box, and this chat then searches only the attached documents. Tap a chip to change the selection, or tap its **x** to remove it. Removing every attached document goes back to searching all documents. Other chats are not affected.

### Ask questions
- With documents in your library, new chats use them automatically. The toolbar menu in a chat has **Use my documents** to turn this on or off.
- Choose **Search all documents** or pick specific documents to restrict the search.
- Answers cite passages like `[1]`. Tap a source chip, or **Why this answer?**, to see the search query and every passage given to the model.
- If the documents do not contain the answer, Applebot says so instead of guessing. Remember that a small on-device model can still make mistakes, so check important facts against the source.

Good questions are specific ("What is the late fee on invoices?") rather than very broad ("Tell me everything"). For broad requests, ask for a summary of one document by choosing it in the search scope.

## Privacy and security

- **Fully on-device.** There are no servers, accounts, or analytics. With connectors off there are no network requests at all. A connector you switch on talks directly from your iPhone to its own service (for example Google) and nowhere else.
- **Encrypted at rest.** Chats and the document library are stored in a protected folder (iOS file protection).
- **App lock.** In **Settings → Privacy**, turn on **Require Face ID / passcode** to lock the app whenever it goes to the background.
- **Delete everything.** **Settings → Delete all chats and documents** erases all data Applebot stores and signs out of connected accounts.

## Settings reference

| Setting | Meaning |
|---|---|
| On-device model | Shows whether Apple Intelligence is ready, and why not if it is unavailable |
| Conversation style | Neutral, Warm companion, or Supportive coach (see [emotional chat](emotional-chat.md)) |
| Passages per answer | How many retrieved passages are given to the model (2 to 6, default 4). More can help recall but the model's context is small, so passages may be trimmed |
| Library | Number of documents and passages, and which embedding model indexes them |
| Require Face ID / passcode | Locks the app in the background |
| Connectors | Connect Gmail and Calendar and switch each on or off (see [connectors](connectors.md)) |

## Limits to be aware of

- The on-device model is much smaller than cloud chatbots. It is best at summarizing, rewriting, extracting facts from your documents, brainstorming, and simple Q&A. It is weak at math, code, and recent world knowledge.
- Its context window is about 4,000 tokens, shared by the conversation, retrieved passages, and the answer.
- The model may decline some requests because of Apple's safety guardrails. Applebot then asks you to put it another way.

See [troubleshooting](troubleshooting.md) if something does not work.
