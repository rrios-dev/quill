# Model providers — contract and catalogue

The model layer lives in `native/quill/packages/ModelKit`, inside Quill's own
package (ARCHITECTURE §1; moved there in PLAN P0-T1). It is a SwiftPM target
with no dependency on any app. This document is its contract.

## 1. The unit of adaptation is the wire protocol

OpenAI, OpenRouter and Vercel AI Gateway all speak the OpenAI **Chat
Completions** protocol, and so do local servers such as Ollama and LM Studio.
So there is one adapter, `ChatCompletionsProvider`, and each of those
"providers" is a **preset**: an endpoint, a descriptor and two dialect switches
(the name of the max-tokens field, optional headers).

A vendor with a different protocol gets its own adapter type. Apple's
Foundation Models framework is one: `AppleOnDeviceProvider`.

## 2. The contract

```swift
public protocol ModelProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func availability() async -> ProviderAvailability
    func models() async throws -> [ModelDescriptor]
    func stream(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, any Error>
    func generate(_ request: GenerationRequest) async throws -> GenerationResult   // default: collects stream
    func prewarm(for request: GenerationRequest) async                           // default: no-op
    func estimateTokens(_ request: GenerationRequest) async -> Int               // default: characters ÷ 3.5
}
```

| Piece | Role |
|---|---|
| `GenerationRequest` | `model`, `instructions`, `input`, `examples`, `options`. Single-shot by design: rewriting a selection has no chat history. |
| `GenerationEvent` | `.delta(String)` while text arrives, then exactly one `.completed(GenerationResult)`. |
| `GenerationResult` | Text, provider, the model **that actually answered** (aggregators route), token usage, latency, and the **finish reason** (`stop`, `length`, `contentFilter`, `unknown`). |
| `ModelDescriptor` | A model: id, name, context size, `pricing` (USD per million tokens) and `vendor` when the model list says. |
| `Recipient` | Who receives the text: `.named` (a brand), `.routedInferenceProvider`, `.modelServingProvider`, `.host` — typed, so the app localizes them. |
| `ProviderError` | The only error that crosses the contract. Callers switch on `code`. |
| `ProviderDescriptor` | What the picker shows without calling the provider: name, traits, tradeoffs. |
| `ModelSelection` | `(provider, model)` — what a profile stores. |
| `ProviderRegistry` | An immutable list of providers; rejects duplicate or malformed ids. The app builds it at launch and rebuilds it when custom servers change (§8 item 9). |
| `CredentialStore` | API keys. Production: `KeychainCredentialStore`. Never `UserDefaults`. |
| `HTTPTransport` | The network seam. Tests inject a scripted transport; no test reaches a real API. |

### Rules every provider keeps

1. **Errors are `ProviderError`.** Vendor errors and HTTP statuses are mapped
   inside the adapter: `authentication`, `rateLimited(retryAfter:)`,
   `contextExceeded`, `refused`, `unavailable(reason)`, `network`, `timeout`,
   `server`, `malformedResponse`, `invalidRequest`, `cancelled`.
2. **Cancellation is honoured and is not a failure.** Cancelling the consumer
   stops the work. A cancelled stream simply ends: Swift's
   `AsyncThrowingStream` finishes iteration instead of throwing. `generate`
   turns that into `.cancelled`. Found by the contract suite: the first draft
   assumed the stream would throw, and `generate` leaked a `CancellationError`.
3. **Credentials are read at call time** from the injected store, so a key
   entered in Settings works immediately; a missing key is reported by
   `availability()` and by the stream **before any network call**.
4. **Deadlines are total, not idle.** `GenerationOptions.timeout` bounds the
   whole generation (default 60 s).
5. **Unset options are omitted** from the request, so each model keeps its own
   default (some reasoning models reject a non-default temperature).

These rules are executable: `ProviderContractTests` runs the same scenarios
against every Chat Completions preset (stream and complete, missing key,
rejected key, cancellation of the stream and of `generate`, timeout, request
shape).

## 3. Advantages and drawbacks are derived, not written

`ProviderDescriptor.tradeoffs` combines:

- **Derived facts** from `ProviderTraits` — where inference runs, who receives
  the text, cost, credential, context size. "Stays on your Mac" and "text
  leaves your Mac" come from the same field, so they cannot both appear.
- **Notes** for what facts cannot express — model quality, catalogue size.

The app maps each `Tradeoff` case to localized copy. `ProviderDescriptorTests`
asserts that the derived claims match the traits for every shipped provider.

## 4. Catalogue

| | Apple Intelligence | OpenRouter | Vercel AI Gateway | OpenAI |
|---|---|---|---|---|
| id | `apple.on-device` | `openrouter` | `vercel-ai-gateway` | `openai` |
| Adapter | `AppleOnDeviceProvider` | Chat Completions | Chat Completions | Chat Completions |
| Endpoint | Foundation Models | `https://openrouter.ai/api/v1` | `https://ai-gateway.vercel.sh/v1` | `https://api.openai.com/v1` |
| Runs | On this Mac | Remote | Remote | Remote |
| Text reaches | Nobody | OpenRouter + the inference provider it routes to (data-collecting providers excluded) — declared so from P1-T0a and P1-T0b (§8 items 5, 7) | Vercel + the provider serving the model — declared so from P1-T0a (§8 item 7) | OpenAI |
| Cost | Free, unlimited | Pay per use | Pay per use | Pay per use |
| Key | None | API key | API key | API key |
| Context | 4,096 tokens | Per model, typically large | Per model, typically large | Per model, large |

**Apple Intelligence** — advantages: free, unlimited, private, offline, no
account. Drawbacks: small model (~3B) that over-edits, under-edits or alters
meaning more often (measured, see the README); 4K context, so long documents
must be split; needs a compatible Mac with Apple Intelligence on; fewer
languages; built-in filters may refuse some texts.

**OpenRouter** — advantages: hundreds of models from many vendors behind one
key; strong models. Drawbacks: paid; the text reaches OpenRouter and the
inference provider it routes the request to, whose data policy varies (Quill
asks for providers that do not collect data); needs a connection.

**Vercel AI Gateway** — advantages: many models behind one key. Drawbacks:
paid; the text reaches Vercel and the provider serving the chosen model;
needs a connection.

**OpenAI** — advantages: a single recipient, no intermediary; strong models.
Drawbacks: paid; OpenAI models only (`Tradeoff.singleVendorCatalog`, §8); the
text reaches OpenAI.

**Custom (OpenAI-compatible)** — any server speaking the protocol. A
non-loopback server must use **https**, or be addressed by a **`.local`
name** over plain http. Loopback (`localhost`, `127.0.0.1`, `::1`) is allowed
over plain http with no exception (measured). App Transport Security blocks plain http to remote
hosts (measured: `-1022`); `NSAllowsLocalNetworking` exempts local names but
not bare IP addresses (measured on a documentation-range address; P4-T1
confirms a private-range one), so the server form accepts https URLs and
`http://<host>.local` URLs and rejects plain http to an IP address with that
explanation. LAN servers need `NSAllowsLocalNetworking` and an
`NSLocalNetworkUsageDescription` in Quill's `Info.plist` plus the user's Local
Network permission, and any `-1022` is mapped to copy suggesting a `.local`
name or https (P4-T1: `ServerAddress` in RewriteKit, `ProviderError.Code.insecureConnection`; the private-range confirmation and a real `.local` server wait for OS6, QA PV-02/PV-03). A loopback
URL (`localhost`) is classified as on-device and free: this is how Ollama or
LM Studio give a private alternative to Apple's model. Because a local proxy
(LiteLLM, for one) can itself forward to the cloud, loopback servers also carry
a drawback note saying that privacy depends on what the local server does
(§8, item 6).

Recommended model ids are **not** in the contract: catalogues change monthly,
and choosing what to recommend is a product decision the app passes in.

## 5. Adding a provider

- **Speaks Chat Completions?** Add a preset in `ChatCompletionsPresets.swift`:
  id, display name, traits, notes, endpoint. Add it to `Preset.all` in
  `ProviderContractTests` and to `ProviderDescriptorTests.shipped`. Done.
- **Different protocol?** Write a type conforming to `ModelProvider`. Build
  `stream` on `GenerationStream.make` to inherit cancellation, the deadline and
  error normalisation. Map every vendor failure onto `ProviderError`. Give it a
  scripted transport fixture and make it pass the same scenarios as the
  contract suite.
- **Then register it** in the app's `ProviderRegistry`. Nothing above the
  contract changes.

Candidates already identified: OpenAI's **Responses** API (recommended by OpenAI
for new work; Chat Completions remains supported with no shutdown date) and
Anthropic's Messages API, each as its own adapter.

## 6. Why not Apple's own provider protocol

The macOS 27 SDK lets third-party models plug into Foundation Models through
`LanguageModel` + `LanguageModelExecutor`, so one `LanguageModelSession` API
could drive every provider. Not adopted, for now:

- It requires macOS 27; the app targets macOS 26.
- It is shaped around Apple's transcript, tools and guided generation. A
  single-shot rewrite needs none of that, and every adapter would pay for it.
- It is weeks old. A small contract of our own is cheap to bridge to it later —
  an adapter in either direction — once it has settled.

## 7. Verification

```bash
cd native/quill && swift test --filter ModelKitTests
# With the real on-device model (needs Apple Intelligence on):
cd native/quill && MODELKIT_LIVE_APPLE=1 swift test --filter AppleOnDeviceProviderTests
```

On 2026-10-03: 31 tests — 29 run by default, all green; the 2 live tests run
with `MODELKIT_LIVE_APPLE=1` and pass on the owner's M2 Max (a Spanish
rewrite in ~2 s, cancellation surfaces `.cancelled`). After P1-T0b: 54 tests
run by default and 6 live ones, all green.

## 8. Amendments (PLAN P1-T0a, P1-T0b; item 9 in P3-T1)

Status: items 1–8 are **implemented** — 1–3, 7, 8 and item 4's protocol
change in P1-T0a, item 4's provider work, 5 and 6 in P1-T0b. Item 9 is P3-T1.

Found by the planning audit, to be made before `RewriteKit` depends on the contract:

1. **Finish reason.** `GenerationResult.finishReason`: `stop`, `length`,
   `contentFilter`, `unknown`. Chat Completions reads `choices[0].finish_reason`.
   Without it, an answer cut off by the output limit looks complete and could
   replace a whole selection with part of it; `RewriteKit` turns `length` into
   the `truncated` state, which can never be applied.
2. **Prewarm and token estimates.** `prewarm(for request:)` (the request
   without its input) and `async estimateTokens(_:)` on `ModelProvider`, with
   defaults (no-op; characters ÷ 3.5). The on-device provider builds a
   **single-use** `LanguageModelSession` from the request's instructions and
   examples at hot-key time, calls `prewarm()`, hands that session to the next
   matching `stream`, and discards it after one generation — a session keeps
   its transcript, so reusing one would carry the previous selection into the
   next prompt and eat the 4,096-token context. Apple advises prewarming only
   with about a second to spare; Quill's gap is shorter, so the gain is
   measured (P5-T4) and not counted in the budgets. Estimates use
   `tokenCount(for:)` behind `#available(macOS 26.4, *)` (it is async, hence
   the async requirement).
3. **Prices and vendor.** `ModelDescriptor.pricing` (input and output USD per
   million tokens) and `vendor`, parsed from model lists that publish them
   (OpenRouter's `pricing` and the `creator/model` id prefix; the Gateway's
   model list where present). Used by the bench's budget and judge rule and by
   the picker's cost estimate; `quill-bench` falls back to its `prices.json`.
4. **On-device provider:**
   - `SystemLanguageModel(guardrails: .permissiveContentTransformations)` —
     Apple's mode for transforming user-supplied text. In this mode string
     generation does not throw `guardrailViolation`; the model may answer with
     a refusal **as text**. `RewriteKit`'s guard G10 catches that
     (ARCHITECTURE §4.6).
   - **No `maximumResponseTokens`.** The framework ends a capped response
     early without an error, so a cut-off answer would report `stop`. The
     provider ignores `GenerationOptions.maxOutputTokens` (documented on the
     option) and relies on the context-overflow error, which the pre-check's
     output reserve makes rare.
   - `contextSize` from the framework (back-deployed to macOS 26.0; it returns
     4,096 on every macOS 26.x) instead of the constant.
   - macOS 27's error types mapped behind `#available(macOS 27, *)`:
     `LanguageModelError` (`contextSizeExceeded`, `rateLimited`,
     `guardrailViolation`, `refusal`, `timeout`, `unsupportedCapability`,
     `unsupportedLanguageOrLocale`, `unsupportedTranscriptContent`,
     `unsupportedGenerationGuide`), `SystemLanguageModel.Error.assetsUnavailable`,
     `LanguageModelSession.Error.concurrentRequests`, and
     `GeneratedContent.ParsingError` → `malformedResponse`. Without this, a
     context overflow on macOS 27 would surface as a generic `server` error.
   - On `rateLimited`: one retry, after a backoff, on a **fresh** session built from
     the request (whether the failed prompt stays in the old session's
     transcript is not documented), using the non-streaming `respond`; if it
     persists, surface `rateLimited` as an error (callers such as the bench
     add their own retries on top). The framework rate-limits
     apps it considers to be in the background — an `LSUIElement` app behind a
     non-activating panel, or a command-line tool, may be one. The Debug →
     Live provider test measures a 30-call burst to find out.
   - `generate(_:)` becomes a protocol requirement (keeping today's
     stream-based default), so the on-device provider can implement it with
     the non-streaming `respond`; the bench uses `generate` (BENCH intro).
     Today it is an extension method, which calls through `any ModelProvider`
     cannot override.
5. **OpenRouter privacy preference.** Every request carries
   `"provider": {"data_collection": "deny"}`, so OpenRouter routes only to
   inference providers that do not collect prompts.
6. **Loopback note.** A `Tradeoff.localServerMayForward` drawback on custom
   loopback servers.
7. **Recipients name the routed party, as typed values the app localizes.**
   `Execution.remote(recipients:)` and `Tradeoff.textLeavesDevice(recipients:)`
   change from `[String]` to `[Recipient]`, with `Recipient` =
   `.named(String)` (a brand, not translated) · `.routedInferenceProvider` ·
   `.modelServingProvider` · `.host(String)`. OpenRouter declares
   `[.named("OpenRouter"), .routedInferenceProvider]`, Vercel
   `[.named("Vercel"), .modelServingProvider]` — today's code names only the
   aggregator, as English strings. (A non-loopback custom server already names its
   host.) `KeychainCredentialStore`'s doc comment is updated to the fixed
   service names of ARCHITECTURE §4.2.
   `Tradeoff.singleVendorCatalog` is added for OpenAI's preset.
8. **Reset support.** `CredentialStore.removeAll()` deletes every item of the
   store's service, so "Reset Quill" also removes keys of custom servers no
   longer listed in `settings.json`.
9. **Registry rebuilds** (app-side, implemented in P3-T1, not in P1-T0a/b). `ProviderRegistry` stays immutable; the app builds a
   new one when custom servers change (ARCHITECTURE §4.2). Done in P3-T1:
   `ProviderRegistryHolder` rebuilds from the shipped providers plus
   `settings.json`'s custom servers whenever that list changes.

**Measured rate limiting** (filled in by P1-T0b and P1-T7a): on-device burst
of 30 calls from inside the app — **not rate-limited**: 30/30 succeeded, 0
retries, p50 306 ms, max 892 ms (the first call, loading the model), through
the streaming path, with Quill in the background behind another frontmost app
(2026-10-03, macOS 26.6.2, Debug → Live provider test); from the `quill-bench`
CLI — **not rate-limited** either: 30/30 through the one-shot `generate`, 0
retries, p50 316 ms, max 1,322 ms (2026-10-03, `Scripts/bench.sh burst`).

Rule 5 of §2 already applies to temperature: `Profile.temperature == nil`
means the option is omitted and each model keeps its default.
