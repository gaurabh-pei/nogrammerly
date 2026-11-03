# Windows LM Studio provider — design

## Intent
Add LM Studio as an explicit AI option to Windows Nogrammerly for a model running on the user's LAN, without breaking the existing Phi Silica or rule-based paths. The user does not use macOS; macOS source and packaging remain unchanged.

## Goals / non-goals
- Choose **Phi Silica**, **LM Studio**, or **rules only** explicitly in the tray UI; preserve the existing local spellchecker and deterministic writing rules for all three.
- Configure and persist an LM Studio base URL and model ID per Windows user. Default URL `http://127.0.0.1:1234/v1` is only a starting value; LAN HTTP(S) hosts are permitted. Do not send text until LM Studio is selected and a model is configured.
- Show the chosen provider and a useful unavailable/error state. A failed selected provider yields rules-only suggestions and the existing deterministic rewrite fallback, **not** another AI provider.
- Maintain the current stale-text protections; prevent old AI results after editing, field changes, pause, or provider/settings changes.
- No macOS work, cloud provider integration, new package dependency, provider framework, per-app rules or cache redesign.

## Constraints and user-visible behavior
- Windows project uses .NET 10, WinForms tray UI, Phi Silica (`AIWriter`), UI Automation (`SystemWritingAssistant`), and `Nogrammerly.Core` parsing/rules. Keep the existing architecture and published Windows tests.
- Add one small settings dialog or equivalent tray entry to set URL and model ID and test/discover `/v1/models`; save syntactically valid values (URL and nonempty model ID) in a per-user app-data JSON file even when the server is offline; model discovery is a separate optional test action. No credentials in the URL; accept only absolute `http`/`https` with a host and `/v1` base path, reject fragments, query strings and embedded credentials. Do not auto-correct an invalid endpoint into another host.
- Explain that LAN HTTP transmits edited text unencrypted on the network; HTTPS can be used if the server supports it. Update the welcome/status wording: only Phi Silica and rules-only stay on this PC. Never claim LM Studio is on-device.
- Explicit selection is sticky across restarts, including when the selected provider is unavailable. Rules are always immediately available; user initiates model download for Phi Silica as before. No hidden automatic provider switching.
- Proofread using LM Studio's OpenAI-compatible `/v1/chat/completions` with selected model and a bounded JSON-schema `response_format`; reuse paragraph splitting and span validation. Rewrites use the existing tone prompt and cleaned content. Reject unusable/malformed responses, bound response size, and use a finite timeout plus cancellation; failures must not crash the worker or block UI Automation. Respect LM Studio's actual model ID rather than assuming a default.
- For LAN use, the user configures LM Studio server binding/firewall themselves; do not start or reconfigure the server from Nogrammerly.

## Approach choice
1. **Chosen — explicit tray provider:** a small setting/selector chooses Phi Silica, LM Studio, or rules only. LAN text transmission occurs only under the LM Studio selection; no automatic cross-provider fallback. Slightly more UI than an auto mode, but transparent and predictable.
2. **Rejected — automatic LM Studio → Phi Silica fallback:** smoother when disconnected but obscures which AI processed a passage and complicates failure semantics.
3. **Rejected — replace Phi Silica outright:** less code initially, but would remove a working offline option and contradict the user's request.

## Proposed shape (builder choices, not user decisions)
- Keep `AIWriter` as the Phi Silica implementation. Add a small `LmStudioWriter` using built-in `HttpClient`/`System.Text.Json`; let `SystemWritingAssistant` route proofreading and rewrites by an explicit provider setting. Avoid an abstract interface/factory unless routing genuinely needs one.
- Put persisted provider/URL/model in one small Windows settings type; the tray UI owns editing/status, and changing settings cancels current AI work and triggers a fresh check of the focused field. Cache only if the current implementation's paragraph cache can be reused safely per provider/model; otherwise leave LM Studio uncached initially. // ponytail: defer caching until latency measurements justify it.
- The existing `Proofreading` parser may be reused for locating suggestions, but structured-output decoding must not rely on grabbing the first `[` and last `]` from arbitrary reply text. Validate model content against a bounded issue array before passing it to span matching; keep legacy native-model handling intact unless a focused test demonstrates a safe simplification.

## Verification and acceptance
- Unit tests with an in-process local fake HTTP server verify request URL/model/schema, settings validation/persistence, response parsing and bounds, cancellation/timeout, no request unless selected, and no fallback to Phi Silica after LM Studio failure. Tests use synthetic text only.
- Existing Windows core/UI Automation tests pass. Windows CI builds/tests; a Windows smoke check against a real LAN LM Studio instance verifies selection, model discovery, proofreading, rewrite, pause, and unavailable status. Such a LAN smoke check requires an accessible endpoint and is not implied by local fake-server tests.
- A Windows-only PR is the preferred publication path; no direct push to `main`.
