# Local model provider — plan

> **Planning record, not shipped behaviour.** Written 2026-09-16 against the
> tree at `8f2d7a4`. The code is authoritative for what actually exists.

## What is being asked

Make the model swappable: keep Gemini as the default, add a **fully on-device
option** so Jot works with no API key, no network, and no audio leaving the Mac.
"Gemma-based" is the starting hypothesis for the local model.

## The thing to get straight first

Gemini is doing **two different jobs** in this app, and only one of them is a job
Gemma can do.

| Job | Who does it today | Local equivalent |
| --- | --- | --- |
| **Speech → text** (the hard one) | `gemini-3.5-transcribe` via `mode: smart` | an ASR model — Whisper, Parakeet, Apple `SpeechTranscriber` |
| **Text → polished text** (tone pass, opt-in) | `gemini-3.5-flash-lite` via `GeminiClient.cleanup` | a small instruct LLM — **this is where Gemma fits** |

Today's default path is **one call** that does both: `mode: "smart"` is what
delivers the product pitch ("say 1pm, actually 2pm → writes 2pm"). Filler
removal, self-correction collapse and list formatting all happen *inside* the
transcription model.

No local ASR does that. Whisper gives you a verbatim transcript, punctuated, and
nothing more. So the local path cannot be one call — it has to be:

```
CAF → 16k mono Float32 → [ASR: Whisper] → verbatim text
                       → [LLM: Gemma 3 instruct] → smart text
                       → ValidationGate → ReplacementEngine → cursor
```

That shape is not new. It is **exactly** the pipeline Jot shipped before native
smart existed — `FormattingPolicy(nativeSmart: false, cleanupPass: true)`, which
`SettingsStore.swift:120` explicitly kept reachable for this kind of reason. The
local provider is that pipeline with both models moved on-device. Reusing it
means `PromptV1.cleanupPrompt`, `ValidationGate`, the auto-degrade counter and
the dictionary guarantee all come along unchanged.

**Consequence worth stating up front:** the local path always runs two models
where Gemini runs one. It also, for the first time, makes `ValidationGate` do
real work on the default local path — there genuinely is a second model to
compare against, which the Gemini smart path lacks (`GeminiTranscriptionService.swift:82-94`).

## Backend choices

### ASR — recommend WhisperKit

| Option | Verdict |
| --- | --- |
| **WhisperKit** (Argmax, Swift + Core ML) | **Pick this.** Swift package, ANE-accelerated, streaming API exists, prebuilt Core ML models on HF (`argmaxinc/whisperkit-coreml`), active project. |
| `whisper.cpp` via SPM C target | Works, more plumbing, no ANE story as clean. Fallback if WhisperKit disappoints. |
| Apple `SpeechTranscriber` (macOS 26+) | Zero download, zero disk, Apple-managed. But raises the deployment floor from 14.0 to 26.0. Ship as an *additional* backend later, not the first one. |
| Parakeet / MLX ASR | Fast and accurate, but Swift integration is thinner than WhisperKit's. Revisit after Phase 1. |

Model tiers to expose (names are HF repo variants, pin exact revisions at
implementation time):

- **Fast** — `distil-whisper_distil-large-v3` or `openai_whisper-small.en`, ~150–500 MB
- **Balanced (default)** — `openai_whisper-large-v3-v20240930_turbo`, ~600 MB quantized
- **Accurate** — `openai_whisper-large-v3`, ~1.5 GB

### Cleanup LLM — recommend Gemma 3 via MLX Swift

| Option | Verdict |
| --- | --- |
| **`gemma-3-4b-it` 4-bit via MLX Swift** | **Pick this as default.** Quality is the binding constraint on the pitch, and 4B is the smallest size likely to collapse self-corrections reliably. ~2.5 GB. Apple Silicon only. |
| `gemma-3-1b-it` 4-bit via MLX Swift | ~700 MB, much faster, noticeably worse at the "change of mind" behaviour. Ship as the **Fast** tier, not the default. |
| Apple Foundation Models (macOS 26+) | ~3B on-device, zero download, zero disk, free. Strongly worth adding as a backend once macOS 26 is a reasonable floor. Guardrails may reject some dictations — needs a fail-open path to raw. |
| `llama.cpp` via SPM | Broadest model support incl. Intel Macs. Heavier integration. Keep in reserve for Intel. |

### Gemma 3n audio-in — explicitly **not** Phase 1

Gemma 3n E2B/E4B accept audio natively, which would collapse the two calls back
into one and make the "Gemma-based" framing literal. It is the right long-term
shape. It is wrong for Phase 1: Swift runtime support is immature relative to
WhisperKit, and its ASR quality on accented speech and jargon is not in the same
class as Whisper large-v3. Revisit as Phase 6 with the eval harness from Phase 5
pointed at it — by then you can answer the question with numbers instead of
opinion.

### Escape hatch — local OpenAI-compatible HTTP server

`SettingsStore.endpointOverride` already exists (`SettingsStore.swift:66-78`).
Pointing the cleanup call at `http://localhost:11434` (Ollama / LM Studio /
`llama-server`) is close to free and lets you A/B local models without rebuilding
the app. Worth wiring as a third provider for power users and for your own
evaluation loop. It does **not** solve ASR — no local server story there is good
enough — so it is a complement, not a substitute.

## Architecture

### The seam already exists

`TranscriptionServicing` (`Services.swift:19`) is the whole boundary, and it is
clean: `transcribe(audioURL:durationSeconds:context:) -> TranscriptionResult`.
`RetryQueue` and `RecoveryScanner` consume it too. A local implementation slots in
with no coordinator changes.

### New types

```
JotCore/Sources/TranscriptionClient/Local/
├── LocalTranscriptionService.swift   # TranscriptionServicing, mirrors GeminiTranscriptionService
├── SpeechRecognizing.swift           # protocol: audio → verbatim text (WhisperKit impl behind it)
├── LocalTextPolishing.swift          # protocol: raw + prompt → polished text (MLX/Gemma impl behind it)
├── WhisperKitRecognizer.swift
├── MLXGemmaPolisher.swift
├── AudioPCMLoader.swift              # CAF → 16k mono Float32 (AVAudioFile + AVAudioConverter)
└── ModelCatalog.swift                # ids, sizes, HF revisions, checksums, disk paths

JotCore/Sources/TranscriptionClient/ModelManager/
├── ModelDownloader.swift             # resumable URLSession download + SHA256 verify + atomic install
├── ModelInventory.swift              # what's installed, what it costs on disk, delete
└── ModelResidency.swift              # load/unload policy, memory pressure handling
```

Two sub-protocols rather than one fat local service, because ASR backend and LLM
backend are chosen independently (WhisperKit + Foundation Models is a legitimate
combination on macOS 26) and because both need fakes in tests.

### Provider routing

`DictationController.init` (`DictationController.swift:88-114`) builds the service
once and hands it to the coordinator as a `let`. Provider is a runtime setting, so
do **not** rebuild the coordinator on change — wrap instead:

```swift
public struct RoutingTranscriptionService: TranscriptionServicing {
    private let gemini: TranscriptionServicing
    private let local: () -> TranscriptionServicing?   // nil when no model installed
    private let settings: SettingsStore

    public func transcribe(...) async throws -> TranscriptionResult {
        // Read ONCE per dictation, same discipline as formattingPolicy today.
        switch settings.transcriptionProvider {
        case .local:  guard let l = local() else { throw .modelNotInstalled(...) }
                      return try await l.transcribe(...)
        case .gemini: return try await gemini.transcribe(...)
        }
    }
}
```

This keeps `RetryQueue` and `RecoveryScanner` working: a dictation that failed
under Gemini and is retried after the user switched to local simply succeeds
locally. That is correct behaviour, and it is free.

### Settings

Add to `SettingsStore`:

```swift
public enum TranscriptionProvider: String, Sendable, CaseIterable { case gemini, local }
public var transcriptionProvider: TranscriptionProvider   // default .gemini
public var localASRModelID: String                         // default "large-v3-turbo"
public var localPolishModelID: String?                     // nil = ASR only, no polish
```

Follow the existing `Self.set(_:forKey:)` pattern so `gtSettingDidChange` fires
and live surfaces update immediately (`SettingsStore.swift:39-42`).

Interlocks, in the spirit of `liveTranscriptionActive` (`SettingsStore.swift:227`):

- `provider == .local` ⇒ live transcription stands down in Phase 1–3 (`makeLiveSession` returns nil). Streaming local lands in Phase 4.
- `provider == .local` ⇒ `usesLegacyTranscribeEndpoint` is irrelevant and hidden.
- `provider == .local` with no polish model ⇒ verbatim only. Say that in the UI plainly; do not let someone believe they still have the change-of-mind behaviour.

### Errors

`TranscriptionError` is HTTP-shaped. Adding cases breaks two exhaustive switches
— `DictationCoordinator.swift:780-793` and `RetryQueue.swift` — which is exactly
what you want: the compiler enumerates every place the failure matrix must learn
a new word.

```swift
case modelNotInstalled(id: String)       // → new .modelMissing failure, "Download it" CTA
case unsupportedHardware(String)         // → terminal, Intel Mac hitting an MLX path
case localInferenceFailed(String)        // → retryable once, like .network
case insufficientMemory                  // → terminal for this model, suggest a smaller tier
```

Two rules that must hold:

1. **Nothing local may map to `.auth` or `.offline`.** Those produce "fix your key"
   and "we'll land it when you reconnect", and both are lies on this path. The
   `RetryQueue`'s network-triggered drain must not hold local failures hostage to
   an `NWPathMonitor` event that has nothing to do with them.
2. **`.offline` becomes unreachable under `.local`.** That is the single biggest
   user-visible win of this feature and it should be said out loud in Settings.

### Dictionary and vocabulary

Gemini takes `customVocabulary` server-side. Whisper's equivalent is prompt
conditioning — pass the sanitized vocabulary as `initialPrompt` / `promptTokens`,
which biases decoding toward those spellings. Weaker than Gemini's mechanism; be
honest about it.

`ReplacementEngine.apply` stays the hard guarantee on every path, unchanged
(`GeminiTranscriptionService.swift:87`, `:215`, `:218`). Same for the spellings
block inside `PromptV1.cleanupPrompt`.

### What the local service reuses verbatim

- `PromptV1.cleanupPrompt` — tone, vocabulary, spellings. No fork.
- `ValidationGate.stripArtifacts` + `.validate` — and here it finally has a real reference.
- `ReplacementEngine` — dictionary guarantee.
- `SettingsStore.recordGateTrip` + auto-degrade — a bad local polish model degrades to verbatim exactly like a bad cleanup model does.
- `TimeoutPolicy.overallDeadline` — a local deadline is still a deadline; a wedged inference must not hang a dictation.

### What it must **not** reuse

- `FLACEncoder` — pointless. Decode the CAF straight to 16k mono Float32.
- `GeminiClient` — different transport entirely.
- The `vocabularySuppressed` latch — that exists because a bad term produces a 400. Local decoding degrades, it does not reject.

## Model download UX

This is the largest genuinely new chunk of work and the one most likely to be
underestimated. Downloading 600 MB–2.5 GB inside a menu-bar app needs:

1. Settings → Model pane: tier picker with **size shown before you commit**, disk usage, delete.
2. Resumable download with progress in the pane *and* in the status item.
3. SHA256 verification and atomic install into Application Support. A half-written model must never be loadable.
4. First-run-after-download warm-up, so the first real dictation is not the one that pays the model-load cost. `WarmEnginePool` (`App/Sources/WarmEnginePool.swift`) is the precedent for where this belongs.
5. Residency policy: keeping a 4B model resident costs ~3 GB RSS for a menu-bar app. Default to unload after N minutes idle, reload on hotkey-down. Measure whether reload cost is acceptable before choosing.
6. Onboarding: `OnboardingWindow.swift:80` has an `.apiKey` step. It becomes a **provider choice** step — "Use Gemini (paste a key)" or "Run locally (download ~600 MB)". Getting this wrong makes local mode invisible.

## Honest expectations

**Latency**, 10s dictation, M-series with ANE, Balanced tier — estimates, not
measurements, to be replaced by Phase 5 numbers:

| Stage | Estimate |
| --- | --- |
| CAF decode → PCM | ~50 ms |
| Whisper large-v3-turbo | 0.6–1.2 s |
| Gemma 3 4B polish (~60 tokens out) | 0.5–1.5 s |
| **Total** | **~1.2–2.7 s** |

Comparable to the Gemini round trip on good network, and *better* than Gemini on
bad network. On a cold model load, add 1–3 s — which is why warm-up matters.

**Quality — expect a drop.** Whisper large-v3 plus a 4B instruct model is not
`gemini-3.5-transcribe` on accents, proper nouns, or domain jargon. The
change-of-mind behaviour in particular moves from being native to the ASR to
being a small local model's instruction-following, which is a real downgrade. The
feature is worth shipping anyway — "works on a plane, with no key, and nothing
leaves the Mac" is a different value proposition, not a worse version of the same
one. Do not market it as parity.

**Disk**: 0.6–3 GB. **RAM while resident**: ~1–4 GB. **Apple Silicon only** for
the MLX path; Intel gets ASR-only or the `llama.cpp` fallback.

## Phases

Each phase ends green and shippable. Estimates assume one person who knows this
codebase and does not already know WhisperKit or MLX Swift.

### Phase 0 — Provider seam (~1 day)
`TranscriptionProvider` in `SettingsStore`, `RoutingTranscriptionService`, new
`TranscriptionError` cases plus the two switch sites they break, a hidden Settings
row. No local inference yet — `.local` throws `.modelNotInstalled`. Tests: routing
picks correctly, provider is read once per dictation, local errors never map to
`.auth`/`.offline`.
**Ships:** nothing user-visible. **Buys:** every later phase is additive.

### Phase 1 — Local ASR (~3–4 days)
WhisperKit dependency in `project.yml`. `AudioPCMLoader`, `WhisperKitRecognizer`,
`LocalTranscriptionService` (verbatim only — no polish). `ModelDownloader` +
Settings model pane. Dictionary terms as `initialPrompt`.
**Ships:** offline verbatim dictation with no API key. Genuinely useful alone.

### Phase 2 — Local polish (~2–3 days)
MLX Swift + `MLXGemmaPolisher`, wired through `PromptV1.cleanupPrompt` and
`ValidationGate`. Second model tier in the download pane. Hardware gate for
Intel.
**Ships:** the change-of-mind behaviour, on-device.

### Phase 3 — Surfaces and truth (~2 days)
Onboarding provider step. Settings copy that states the trade honestly.
`README.md` and `docs/PRIVACY.md` — both currently claim "one network host"
(`README.md`, "private by architecture"), which under local mode becomes **zero**
after download. That is a headline, not a footnote. `THIRD_PARTY_NOTICES.md` for
WhisperKit (MIT), MLX Swift (MIT), Whisper weights (MIT) and **Gemma Terms of
Use** — Gemma is not OSI-licensed and the terms need surfacing at download time.
**Ships:** a feature people can find and understand.

### Phase 4 — Local streaming (~3 days, optional)
WhisperKit streaming behind `LiveTranscribing`. The existing contract makes this
safe: `finish` returns optional, and anything short of clean falls back to batch
(`LiveTranscribing.swift:29-56`). The byte-reconciliation check has no local
analogue — replace with an explicit local equivalent rather than dropping it and
hoping.
**Ships:** live partials without a socket, which is strictly more reliable than
the Gemini live path.

### Phase 5 — Eval harness (~2 days)
Fixed audio corpus (accents, jargon, self-corrections, lists, silence, noise),
run every provider × tier, report WER plus a change-of-mind pass rate. Without
this every model question is opinion. **Do this before Phase 6.**

### Phase 6 — Gemma 3n audio-in (research spike)
One model, one call, literally Gemma-based. Judge it on Phase 5's numbers.

**Total: ~2–3 weeks** for Phases 0–3 plus 5. Phase 4 and 6 are separable.

## Risks

1. **Quality disappointment.** Mitigate by shipping Phase 1 (verbatim, honest) before Phase 2, and by naming the trade in Settings copy rather than in a changelog nobody reads.
2. **MLX is Apple-Silicon-only.** Intel Macs are in scope per `PLAN.md`. Phase 2 must gate on hardware and degrade to ASR-only, not crash.
3. **App size and notarization.** Models download at runtime, never bundled. Keep the DMG small and the hardened-runtime entitlements unchanged. Verify JIT/Metal entitlement needs for MLX early — this is the kind of thing found at notarization time otherwise.
4. **Memory pressure in a background app.** A resident 4B model in a menu-bar app is antisocial. Residency policy is a Phase 2 requirement, not a Phase 2 nice-to-have.
5. **Two models mean two failure modes.** ASR succeeding and polish failing must insert the verbatim transcript, exactly as `cleanupOrFallback` already does (`GeminiTranscriptionService.swift:219-224`). Copy that discipline rather than reinventing it.
6. **Upstream churn.** WhisperKit and mlx-swift-examples move fast. Pin exact versions in `project.yml`; do not track `main`.

## Open questions

1. **Default provider.** Recommendation: Gemini stays the default. The repo is a Gemini 3.5 Transcribe demo and local mode is an opt-in. Flip only if Phase 5 numbers say otherwise.
2. **Deployment floor.** Staying on macOS 14 forces WhisperKit + MLX. Moving to 26 unlocks `SpeechTranscriber` + Foundation Models — zero downloads, zero disk, a much simpler product — at the cost of every pre-26 user. Worth a deliberate decision, not a drift.
3. **Is verbatim-only local mode enough for v1?** If yes, Phase 2 can wait and this ships in about a week.
