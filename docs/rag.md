# Retrieval-augmented generation (RAG)

How Applebot answers questions about your documents, and how retrieval quality is measured.

## Ingestion

`KnowledgeBase.ingest(title:blocks:)`:

1. **Extract** text via `DocumentExtractor`:
   - Text, Markdown, CSV, JSON, YAML, log: read as UTF-8 (falls back to Latin-1).
   - RTF: parsed with `NSAttributedString`.
   - PDF: `PDFKit` text per page. Pages with fewer than 20 characters are rendered and run through Vision OCR (scanned documents).
   - Images (PNG, JPEG, HEIC, TIFF, GIF, BMP): Vision OCR.
2. **Fingerprint** the normalized text (128-bit FNV-1a). Identical content is reported as `duplicate` and skipped.
3. **Chunk** with `Chunker` (defaults: target 250 tokens, hard cap 320, 15% sentence overlap):
   - Markdown headings (`#`) and short ALL-CAPS lines start a new chunk and become the chunk's `heading`.
   - Paragraphs are packed up to the target. Oversized paragraphs split into sentences, and oversized sentences into word windows.
   - A tiny final chunk is merged into the previous one when they share a heading.
   - Page numbers are carried through for PDFs.
4. **Embed** `heading + text` in batches of 16 (progress is reported 0 to 1).
5. **Persist** the document and chunks (with vectors) in one SQLite transaction, then add them to the in-memory index.

## Embedders

| Embedder | Notes |
|---|---|
| `NLContextualEmbedder` | Transformer-based `NLContextualEmbedding`, mean-pooled. Best quality; used only when its assets are already on the device. `requestAssets()` can download them once while online |
| `NLSentenceEmbedder` | Built-in `NLEmbedding.sentenceEmbedding`; no download; the default fallback |
| `HashingEmbedder` | Pure-Swift feature hashing of unigrams and bigrams. Lexical only, but deterministic and portable; used in tests and the Linux eval |

`EmbedderFactory.preferred()` chooses the best one that works offline right now. Each embedder has a stable `identifier`; a change triggers automatic re-embedding.

## Retrieval

`KnowledgeBase.search(query:limit:scope:config:)` embeds the query and runs two rankers over up to `candidatePool` (default 20) candidates:

1. **Vector search**: brute-force cosine similarity (vectors are unit length, so a dot product; Accelerate on Apple platforms).
2. **BM25 keyword search** over the same text (stopwords removed, light plural stemming).

They are fused with **Reciprocal Rank Fusion**: `score = Σ weight / (60 + rank)`. Then **MMR** (`mmrLambda` 0.75) re-ranks to drop near-duplicates. `RetrievalConfig` also supports weights, a minimum cosine for vector-only hits, and a document scope.

Follow-up questions are first rewritten to a standalone query by the model, so "where is the button?" becomes something searchable.

## Grounded generation

When documents are enabled, `PromptBuilder` instructs the model to answer using only the numbered passages, to cite them as `[n]`, and to reply exactly *"I couldn't find that in your documents."* otherwise. The pipeline parses `[n]` markers and flags `notFound`. The app stores every retrieved passage with a `cited` flag, which powers the source chips and **Why this answer?**.

## Evaluating retrieval

Retrieval quality is tested without any LLM:

- Fixtures: `tests/fixtures/docs/*.md` and labelled questions in `tests/fixtures/eval.json`:

  ```json
  { "question": "When are the estimated tax payments due?", "document": "tax-notes", "phrase": "June 15" }
  ```

- `RetrievalEvaluator.evaluate` computes **recall@k** (did a correct chunk appear in the top k?) and **MRR**.
- `tests/RAGKitTests/RetrievalEvalTests.swift` enforces thresholds in CI (recall@4 ≥ 0.9, MRR ≥ 0.7, recall@1 ≥ 0.7, and hybrid ≥ vector-only). The current lexical baseline scores recall@4 = 1.0 and MRR ≈ 0.93.

Run just the eval:

```bash
docker compose run --rm eval
```

To tune retrieval, add a document and cases to `tests/fixtures`, change `ChunkerConfig` or `RetrievalConfig`, and compare the printed `retrieval eval: recall@4=… mrr=…` line.

## Tuning tips

| Symptom | Try |
|---|---|
| Answers miss details that are in a document | Smaller `targetTokens` (150 to 200) or more passages per answer in Settings |
| Passages are cut off | Fewer passages per answer, or smaller chunks, because the context window is shared |
| Paraphrased questions miss | Make sure a semantic embedder is in use (Settings → Library → Embeddings should start with `nl-`) |
| Same fact repeated in several passages | Lower `mmrLambda` for more diversity |
