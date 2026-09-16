# Local model provider — plan

> **Planning record, not shipped behaviour.** Written 2026-09-16 against the
> tree at `8f2d7a4`. The code is authoritative for what actually exists.
> Model-landscape claims are sourced at the bottom and were checked on
> 2026-09-16; this is a fast-moving area and they decay.

## What is being asked

Make the model swappable: keep Gemini as the default, add a **fully on-device
option** so Jot works with no API key, no network, and no audio leaving the Mac.

## The thing to get straight first

Gemini is doing **two different jobs** in this app, and they want different
local models.

| Job | Who does it today | Local equivalent |
| --- | --- | --- |
| **Speech → text** (the hard one) | `gemini-3.5-transcribe` via `mode: smart` | a dedicated ASR model — Parakeet, Whisper |
| **Text → polished text** (tone pass, opt-in) | `gemini-3.5-flash-lite` via `GeminiClient.cleanup` | a small instruct LLM — **this is where Gemma fits** |

Today's default path is **one call** that does both: `mode: "smart"` is what
delivers the product pitch ("say 1pm, actually 2pm → writes 2pm"). Filler
removal, self-correction collapse and list formatting all happen *inside* the
transcription model.

No local ASR does that. Parakeet and Whisper give you a verbatim transcript and
nothing more. So the local path cannot be one call — it has to be:

```
CAF → 16k mono Float32 → [ASR: Parakeet TDT v3] → verbatim text
                       → [LLM: Gemma 4 E4B]     → smart text
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
compare against, which the Gemini smart path lacks
(`GeminiTranscriptionService.swift:82-94`).

## Backend choices

### ASR — recommend Parakeet TDT v3 via FluidAudio

| Option | Verdict |
| --- | --- |
| **Parakeet TDT 0.6B v3 via FluidAudio** | **Pick this.** Swift SPM package, runs on the ANE (not GPU/MPS), macOS 14.0+ Apple Silicon — matching Jot's existing floor exactly. ~100 ms latency. Already shipping in Spokenly, VoiceInk and MacParakeet, so the integration path is proven for precisely this use case. 25 European languages plus Japanese and Chinese. |
| **WhisperKit** | **Ship as the second backend.** 99 languages and Intel CPU support — the two things Parakeet lacks. Slower (~200–500 ms). This is the fallback for non-Parakeet languages and Intel Macs, not the default. |
| Cohere Transcribe (2B) | #1 on the Open ASR Leaderboard (5.42% avg WER), open weights. Worth evaluating in Phase 5; no first-party Swift path yet. |
| Apple `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+) | Zero download, zero disk, Apple-managed. Raises the deployment floor from 14.0 to 26.0. Add later as a third backend, not first. |

FluidAudio also brings VAD and diarization, neither of which Jot needs today —
but VAD is interesting later for the "keeps listening until you actually stop"
behaviour.

### Cleanup LLM — recommend Gemma 4 E4B via MLX Swift

Gemma 4 shipped 2026-04-02 and is a materially better fit than Gemma 3 for two
reasons beyond raw quality:

1. **Apache 2.0.** Gemma 3 carried Google's custom Gemma Terms of Use, which
   would have needed surfacing at download time. Gemma 4 does not. That removes
   a whole licensing conversation from Phase 3.
2. **Built from Gemini 3 research**, with configurable thinking modes — the
   cleanup call already minimises thinking on the Gemini side
   (`GeminiClient.swift:100-107`), so the knob maps across.

| Option | Verdict |
| --- | --- |
| **`gemma-4-E4B-it` 4-bit via MLX Swift** | **Default.** 4.5B effective / 8B with embeddings, ≈4–5 GB at 4-bit (verify). Quality is the binding constraint on the change-of-mind pitch and E4B is the smallest size likely to hold it. |
| `gemma-4-E2B-it` 4-bit | 2.3B effective / 5.1B with embeddings, ≈3 GB at 4-bit. The **Fast** tier. Google explicitly targets E2B/E4B at mobile and edge. |
| Apple Foundation Models (macOS 26+) | ~3B on-device, zero download, zero disk. Very attractive for a menu-bar app where 4 GB resident is antisocial. Guardrails may reject some dictations — needs a fail-open path to raw. |
| `gemma-4-12B` and up | Out of scope. A menu-bar dictation app cannot justify the footprint. |

**Implementation gotcha, worth knowing before you start:** Gemma 4 is registered
in MLX Swift on the **VLM** side (`MLXVLM/VLMModelFactory.swift`), *not* MLXLLM.
Loading `gemma-4-E2B-it-4bit` through `LLMModelFactory` fails with
`unsupportedModelType`. Use `VLMModelFactory` with a text-only prompt. Also note
the examples repo is now **`mlx-swift-lm`**, succeeding `mlx-swift-examples`.

### Gemma 4 audio-in — evaluated, and the answer is no

This is the obvious idea: E2B/E4B/12B accept audio natively and the model card
explicitly lists ASR. One model, one call, literally Gemma-based. I planned to
defer it as a research spike. Having checked the numbers, it should be **ruled
out for this product**, not merely deferred:

- **It falls apart on hard audio.** Independent benchmarking across the eight
  Open ASR Leaderboard datasets: E4B is genuinely good on LibriSpeech Clean
  (3.05% WER, beating `whisper base.en`) but the family is unreliable elsewhere
  — the 12B posts 104% WER on AMI, 50% on Earnings22, 54% on SPGISpeech. The
  benchmark author's own conclusion is that it is "a general-purpose capability
  rather than a drop-in replacement for a dedicated ASR model."
- **Dictation is the hard case, not the clean one.** Real rooms, accents, jargon
  and self-corrections are what Jot exists to handle. LibriSpeech-clean
  performance is the least relevant number on the board.
- **Scaling reverses.** The 12B is both the slowest and the least accurate of the
  three. That is not a curve you want to be standing on.
- **Speed is 20× off.** E4B runs ~178× real-time against Parakeet's ~3,386×.
- **Swift audio support does not exist.** `mlx-swift-lm` has an open feature
  request for the Gemma 4 audio encoder; the missing pieces are substantial
  (HTK mel filterbanks, STFT via MLXFFT, Conformer blocks, chunked local
  attention). There is one third-party repo and a Python `mlx-vlm` path, and
  early `mlx-vlm` Gemma 4 audio reportedly *hallucinated* due to encoder bugs.
- **No timestamps, no diarization.**

Keep Parakeet for hearing and Gemma for writing. Revisit only if Phase 5's
harness later says otherwise.

### Escape hatch — local OpenAI-compatible HTTP server

`SettingsStore.endpointOverride` already exists (`SettingsStore.swift:66-78`).
Pointing the cleanup call at `http://localhost:11434` (Ollama / LM Studio /
`llama-server`) is close to free and lets you A/B polish models without
rebuilding. Worth wiring for power users and for your own evaluation loop. It
does **not** solve ASR, so it is a complement, not a substitute.

## Architecture

### The seam already exists

`TranscriptionServicing` (`Services.swift:19`) is the whole boundary, and it is
clean: `transcribe(audioURL:durationSeconds:context:) -> TranscriptionResult`.
`RetryQueue` and `RecoveryScanner` consume it too. A local implementation slots
in with no coordinator changes.

### New types

```
JotCore/Sources/TranscriptionClient/Local/
├── LocalTranscriptionService.swift   # TranscriptionServicing, mirrors GeminiTranscriptionService
├── SpeechRecognizing.swift           # protocol: audio → verbatim text
├── LocalTextPolishing.swift          # protocol: raw + prompt → polished text
├── ParakeetRecognizer.swift          # FluidAudio
├── WhisperKitRecognizer.swift        # fallback backend
├── MLXGemmaPolisher.swift            # Gemma 4 via VLMModelFactory
├── AudioPCMLoader.swift              # CAF → 16k mono Float32 (AVAudioFile + AVAudioConverter)
└── ModelCatalog.swift                # ids, sizes, HF revisions, checksums, disk paths

JotCore/Sources/TranscriptionClient/ModelManager/
├── ModelDownloader.swift             # resumable URLSession download + SHA256 verify + atomic install
├── ModelInventory.swift              # what's installed, what it costs on disk, delete
└── ModelResidency.swift              # load/unload policy, memory pressure handling
```

Two sub-protocols rather than one fat local service, because the ASR and LLM
backends are chosen independently (Parakeet + Foundation Models is a legitimate
combination on macOS 26) and because both need fakes in tests.

### Provider routing

`DictationController.init` (`DictationController.swift:88-114`) builds the
service once and hands it to the coordinator as a `let`. Provider is a runtime
setting, so do **not** rebuild the coordinator on change — wrap instead:

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

```swift
public enum TranscriptionProvider: String, Sendable, CaseIterable { case gemini, local }
public var transcriptionProvider: TranscriptionProvider   // default .gemini
public var localASRModelID: String                         // default "parakeet-tdt-0.6b-v3"
public var localPolishModelID: String?                     // nil = ASR only, no polish
```

Follow the existing `Self.set(_:forKey:)` pattern so `gtSettingDidChange` fires
and live surfaces update immediately (`SettingsStore.swift:39-42`).

Interlocks, in the spirit of `liveTranscriptionActive` (`SettingsStore.swift:227`):

- `provider == .local` ⇒ live transcription stands down in Phases 1–3 (`makeLiveSession` returns nil). Streaming local lands in Phase 4.
- `provider == .local` ⇒ `usesLegacyTranscribeEndpoint` is irrelevant and hidden.
- `provider == .local` with no polish model ⇒ verbatim only. Say that in the UI plainly; do not let someone believe they still have the change-of-mind behaviour.

### Errors

`TranscriptionError` is HTTP-shaped. Adding cases breaks two exhaustive switches
— `DictationCoordinator.swift:780-793` and `RetryQueue.swift` — which is exactly
what you want: the compiler enumerates every place the failure matrix must learn
a new word.

```swift
case modelNotInstalled(id: String)       // → new .modelMissing failure, "Download it" CTA
case unsupportedHardware(String)         // → terminal, Intel Mac hitting a Parakeet/MLX path
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

Gemini takes `customVocabulary` server-side. Parakeet TDT has no equivalent
prompt-conditioning hook — this is a **real regression** on the local path, and
bigger than it looks, because "your jargon, spelled right" is one of the four
pitches in the README. Mitigations, in order of preference:

1. Lean harder on `ReplacementEngine` — it already runs on every path as a hard
   guarantee (`GeminiTranscriptionService.swift:87`, `:215`, `:218`).
2. Pass the vocabulary into the **Gemma polish prompt**, which
   `PromptV1.cleanupPrompt` already does. Correction moves from the recogniser to
   the polisher — later than ideal, but it exists.
3. WhisperKit's `initialPrompt` does support biasing, so the fallback backend
   keeps the feature. Worth surfacing that asymmetry in Settings.

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

The largest genuinely new chunk of work, and the one most likely to be
underestimated. Note the asymmetry: Parakeet is ~600 MB and Gemma 4 E4B is
~4–5 GB, so **Phase 1 alone is a very modest download** and Phase 2 is where the
footprint conversation actually starts.

1. Settings → Model pane: tier picker with **size shown before you commit**, disk usage, delete.
2. Resumable download with progress in the pane *and* in the status item.
3. SHA256 verification and atomic install into Application Support. A half-written model must never be loadable.
4. Warm-up after download, so the first real dictation does not pay the model-load cost. `WarmEnginePool` (`App/Sources/WarmEnginePool.swift`) is the precedent for where this belongs.
5. Residency policy. A resident E4B costs ~4 GB RSS in a menu-bar app. Default to unload after N minutes idle, reload on hotkey-down; measure reload cost before committing. Parakeet on the ANE is small enough to stay resident.
6. Onboarding: `OnboardingWindow.swift:80` has an `.apiKey` step. It becomes a **provider choice** step — "Use Gemini (paste a key)" or "Run locally (download ~600 MB)". Getting this wrong makes local mode invisible.

## Honest expectations

**Latency**, 10s dictation, Apple Silicon with ANE — estimates to be replaced by
Phase 5 numbers:

| Stage | Estimate |
| --- | --- |
| CAF decode → PCM | ~50 ms |
| Parakeet TDT v3 (ANE) | ~100 ms |
| Gemma 4 E4B polish (~60 tokens out) | 0.5–1.5 s |
| **Total, verbatim only (Phase 1)** | **~150 ms** |
| **Total, with polish (Phase 2)** | **~0.7–1.7 s** |

Phase 1 is *dramatically* faster than the Gemini round trip — around 150 ms
against a network call. That is a real product win on its own and an argument for
shipping verbatim-only local mode early rather than holding it for Phase 2.

**Quality — expect a drop, but a smaller one than I first assumed.** Parakeet
tops the Open ASR Leaderboard, so raw recognition is competitive. The losses are
specific and nameable: no `customVocabulary` biasing, and the change-of-mind
behaviour moves from being native to the ASR to being a 4B model's
instruction-following. Do not market it as parity.

**Disk**: ~600 MB (Phase 1) to ~5.5 GB (both models). **RAM while resident**:
~0.5 GB to ~4.5 GB. **Apple Silicon only** for both Parakeet and MLX; Intel Macs
get the WhisperKit backend and no polish.

## Phases

Each phase ends green and shippable. Estimates assume one person who knows this
codebase and does not already know FluidAudio or MLX Swift.

### Phase 0 — Provider seam (~1 day)
`TranscriptionProvider` in `SettingsStore`, `RoutingTranscriptionService`, new
`TranscriptionError` cases plus the two switch sites they break, a hidden
Settings row. No local inference yet — `.local` throws `.modelNotInstalled`.
Tests: routing picks correctly, provider is read once per dictation, local errors
never map to `.auth`/`.offline`.
**Ships:** nothing user-visible. **Buys:** every later phase is additive.

### Phase 1 — Local ASR (~3 days)
FluidAudio in `project.yml`. `AudioPCMLoader`, `ParakeetRecognizer`,
`LocalTranscriptionService` (verbatim only). `ModelDownloader` + Settings model
pane. Hardware gate for Intel.
**Ships:** offline verbatim dictation, no API key, ~150 ms, ~600 MB. The
strongest standalone increment in the plan.

### Phase 2 — Local polish (~2–3 days)
MLX Swift + `MLXGemmaPolisher` via `VLMModelFactory`, wired through
`PromptV1.cleanupPrompt` and `ValidationGate`. Second model tier in the download
pane. Residency policy.
**Ships:** the change-of-mind behaviour, on-device.

### Phase 3 — Surfaces and truth (~2 days)
Onboarding provider step. Settings copy stating the trade honestly, including the
vocabulary regression. `README.md` and `docs/PRIVACY.md` — both currently claim
"one network host", which under local mode becomes **zero** after download. That
is a headline, not a footnote. `THIRD_PARTY_NOTICES.md` for FluidAudio, MLX
Swift, Parakeet weights and Gemma 4 — **all Apache 2.0 or MIT**, so this is now
routine rather than a licensing conversation.
**Ships:** a feature people can find and understand.

### Phase 4 — Local streaming (~3 days, optional)
FluidAudio streaming behind `LiveTranscribing`. The existing contract makes this
safe: `finish` returns optional, and anything short of clean falls back to batch
(`LiveTranscribing.swift:29-56`). The byte-reconciliation check has no local
analogue — replace it with an explicit local equivalent rather than dropping it
and hoping. At ~100 ms this is closer to genuine real-time than the Gemini live
path and has no socket to die mid-sentence.

### Phase 5 — Eval harness (~2 days)
Fixed audio corpus (accents, jargon, self-corrections, lists, silence, noise),
run every provider × tier, report WER plus a change-of-mind pass rate. Without
this every model question is opinion. Evaluate Cohere Transcribe here.

**Total: ~2 weeks** for Phases 0–3 plus 5. Phase 4 is separable.

*(The previous revision had a Phase 6 for Gemma audio-in. It is cut — see
"Gemma 4 audio-in" above.)*

## Risks

1. **Vocabulary regression.** Parakeet has no `customVocabulary` equivalent, and "your jargon, spelled right" is a headline feature. Mitigate via `ReplacementEngine` and the Gemma prompt; be explicit in Settings copy.
2. **Apple Silicon only.** Both Parakeet and MLX require it, and Intel Macs are in scope per `PLAN.md`. Phase 1 must gate on hardware and route Intel to WhisperKit, not crash.
3. **Memory in a background app.** A resident 4 GB model in a menu-bar app is antisocial. Residency policy is a Phase 2 requirement, not a nice-to-have.
4. **MLX Gemma 4 loads through `VLMModelFactory`, not `LLMModelFactory`.** Known trap; costs an afternoon if hit blind.
5. **App size and notarization.** Models download at runtime, never bundled. Verify JIT/Metal entitlement needs for MLX early — the kind of thing otherwise found at notarization time.
6. **Two models mean two failure modes.** ASR succeeding and polish failing must insert the verbatim transcript, exactly as `cleanupOrFallback` already does (`GeminiTranscriptionService.swift:219-224`). Copy that discipline rather than reinventing it.
7. **Upstream churn.** FluidAudio and mlx-swift-lm move fast. Pin exact versions in `project.yml`; do not track `main`.

## Open questions

1. **Default provider.** Recommendation: Gemini stays the default. The repo is a Gemini 3.5 Transcribe demo and local mode is an opt-in. Flip only if Phase 5 numbers say otherwise.
2. **Deployment floor.** Staying on macOS 14 is now *cheap* — FluidAudio's floor is macOS 14.0 Apple Silicon, matching Jot exactly. Moving to 26 would unlock `SpeechTranscriber` + Foundation Models (zero downloads, zero disk) but the case is weaker than it was before Parakeet entered the picture.
3. **Is verbatim-only local mode enough for v1?** Phase 1 delivers ~150 ms offline dictation for a 600 MB download. That is a shippable product in about a week, and Phase 2 quadruples the disk footprint for one behaviour. Genuinely worth deciding deliberately.

## Sources

- [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4) — sizes, audio support, Apache 2.0
- [Gemma 4 announcement](https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/)
- [How Good is Gemma 4 at ASR Tasks?](https://twango.dev/writing/gemma4-asr-benchmark) — per-dataset WER and RTFx
- [Gemma 4 audio with MLX](https://simonwillison.net/2026/Apr/12/mlx-audio/) — early tooling state
- [mlx-swift-lm issue #207](https://github.com/ml-explore/mlx-swift-lm/issues/207) — Gemma 4 audio encoder gap
- [mlx-swift-lm issue #282](https://github.com/ml-explore/mlx-swift-lm/issues/282) — loader gaps
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Swift ANE ASR SDK
- [Parakeet vs Whisper: Best Local Speech Model 2026](https://spokenly.app/blog/parakeet-vs-whisper)
- [Best Local Speech-to-Text Models in 2026](https://www.onresonant.com/resources/local-stt-models-2026)
