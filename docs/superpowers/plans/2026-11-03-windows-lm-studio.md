# Windows LM Studio Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit Phi Silica / configurable LAN LM Studio / rules-only selection to Windows Nogrammerly without silently switching AI providers.

**Architecture:** Keep `AIWriter` for Phi Silica and the existing immediate spelling/rules pipeline. Add a small `LmStudioWriter` using `HttpClient` and a per-user settings record. Route asynchronous AI calls by the saved selection; cancellation and a field/settings generation prevent stale work from publishing or replacing text.

**Tech Stack:** .NET 10, WinForms, `System.Net.Http`, `System.Text.Json`, existing xUnit v3 Windows tests.

**Spec:** `docs/superpowers/specs/2026-11-03-windows-lm-studio-design.md`

## Global Constraints

- Windows only; do not alter `Sources/`, Swift workflows, or macOS packaging.
- No additional NuGet package, cloud provider, provider factory, per-app controls, or LM response cache.
- LAN HTTP(S) URL and model ID must be configurable and persistent; syntactic validation must work offline.
- Explicit selection only; a selected but failed provider falls back to deterministic rules, never the other AI.
- Preserve no-read password controls, existing stale-text validation, and Phi Silica download flow.
- Use synthetic text in tests; do not require a real LM Studio instance for CI.

## Review Focus

1. Old proofread result after switching between two fields containing *identical text* must not appear in the new field — Task 3 test.
2. Provider selection/settings change during a pending rewrite must not replace text — Task 3 test.
3. Redirect from a configured LAN host to an unrelated host must not transmit text — Task 2 test (disable HTTP redirects).
4. Malformed/unbounded model output must not crash or create suggestions — Task 2 test.
5. Saved LM Studio selection must remain selected when server is offline — Task 1 test.

## Files and ownership

- Create `windows/Nogrammerly/AppSettings.cs`: selection enum, settings URL/model validation, JSON load/save in LocalAppData.
- Create `windows/Nogrammerly/LmStudioWriter.cs`: model probe, structured proofreading, rewrite and bounded HTTP responses.
- Modify `windows/Nogrammerly/SystemWritingAssistant.cs`: provider dispatch, cancellation/generation checks, failure notice.
- Modify `windows/Nogrammerly/TrayApp.cs`: selection, small connection editor, connectivity feedback and accurate privacy copy.
- Modify `windows/Nogrammerly.Core/Proofreading.cs`: safe bounded structured issue parsing while keeping existing native parsing behavior.
- Extend `windows/Nogrammerly.Tests/WindowsTests.cs` for settings, HTTP and routing checks; extend `windows/Nogrammerly.Core.Tests/ProofreadingTests.cs` for parser bounds.
- Update the Windows section of `README.md` (locate the actual section before editing) with LAN setup and privacy warning.

### Task 1: Persistent, explicit provider configuration

**Files:** Create `windows/Nogrammerly/AppSettings.cs`; modify `windows/Nogrammerly.Tests/WindowsTests.cs`.

**Interfaces:** Define `internal enum AiProvider { PhiSilica, LmStudio, RulesOnly }`; `internal sealed record AppSettings(AiProvider Provider, string BaseUrl, string ModelId)` with `Default`, `TryValidate(out string error)`, `Load(string path)`, `Save(string path)`. Use `Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Nogrammerly", "settings.json")` as the production path. Default provider Phi Silica; default URL `http://127.0.0.1:1234/v1`; empty model ID means LM Studio cannot be enabled until set. Save valid settings to user-local JSON; malformed JSON returns defaults with a visible notice in the later UI task rather than silently transmitting text.

- [ ] Write xUnit tests for valid LAN HTTP(S) and offline save/load; reject missing model *when selecting LM Studio*, URL credentials/query/fragment, non-HTTP scheme, and paths other than `/v1`; invalid stored settings cannot enable LM Studio.
- [ ] Run `dotnet test --project windows/Nogrammerly.Tests` on Windows; confirm new tests fail.
- [ ] Implement only the settings record, validation and persistence using `System.Text.Json`. Keep Phi Silica and rules-only usable with an empty model ID. // ponytail: no settings framework or server reachability check at save time.
- [ ] Re-run `dotnet test --project windows/Nogrammerly.Tests`; expect pass.
- [ ] Commit the task with explicit `git add` paths and message `feat(windows): persist explicit AI provider settings` when Git identity is available.

### Task 2: Bounded LM Studio adapter and parser

**Files:** Create `windows/Nogrammerly/LmStudioWriter.cs`; modify `windows/Nogrammerly.Core/Proofreading.cs`, `windows/Nogrammerly.Tests/WindowsTests.cs`, `windows/Nogrammerly.Core.Tests/ProofreadingTests.cs`.

**Interfaces:** `internal sealed class LmStudioWriter` owns a `HttpClient` with redirects disabled; exposes `Task<IReadOnlyList<WritingSuggestion>> ProofreadAsync(string text, AppSettings settings, CancellationToken token)`, `Task<string?> RewriteAsync(string text, WritingTone tone, AppSettings settings, CancellationToken token)`, `Task<IReadOnlyList<string>> ModelsAsync(AppSettings settings, CancellationToken token)`, and `string? LastError` for tray status (cleared on success; never includes submitted text). Add `Proofreading.ParseStructuredIssues(string json, string paragraph)` in core; require root object with `issues` array, capped at 30 items, each string at most 500 characters and a recognized kind, then locate only verbatim non-overlapping spans using existing logic. Preserve `ParseIssues` for Phi Silica; reject non-array roots safely there too.

- [ ] Write core tests: valid `{"issues":[...]}` produces positioned issues; reject non-object root, malformed JSON, too many items, oversized fields, wrong kind and text not present. Add Windows tests with a loopback `TcpListener` fake HTTP server: assert POST `/v1/chat/completions` uses selected model and schema `response_format`; GET `/v1/models` reads IDs; rewrite output cleaned; timeout/cancellation, HTTP error, truncated/oversized reply and redirect return no usable AI result; no request to redirect destination. Use synthetic content only.
- [ ] Run `dotnet test --project windows/Nogrammerly.Core.Tests` and `dotnet test --project windows/Nogrammerly.Tests` on Windows; confirm targeted new tests fail.
- [ ] Implement with a client created using `HttpClientHandler.AllowAutoRedirect = false` (never accept a caller-supplied client that can follow redirects), a 15-second request timeout, per-call cancellation, maximum response body of 256 KiB, and OpenAI-compatible completion messages. Proofreading uses `response_format: {type:"json_schema", json_schema:{name:"issues", strict:true, schema:...}}` with an object containing the `issues` array and required fields. Iterate `Proofreading.Paragraphs(text)` and translate spans back to document offsets. Rewrites use `Proofreading.RewritePrompt`, then `Proofreading.CleanRewrite`; model probe uses only `/v1/models`. Reject invalid/nontext response content without throwing onto the worker; set `LastError` to a concise category such as timeout, HTTP status, or malformed reply, never text or full URL.
- [ ] Re-run both test projects; expect pass.
- [ ] Commit with message `feat(windows): add bounded LM Studio client` when identity is available.

### Task 3: Route the selected provider and guard stale work

**Files:** Modify `windows/Nogrammerly/SystemWritingAssistant.cs`, `windows/Nogrammerly.Tests/WindowsTests.cs`.

**Interfaces:** Constructor takes current `AppSettings` plus `LmStudioWriter` (production app supplies both); expose `UpdateSettings(AppSettings settings)` on the worker queue. Existing public actions remain. The settings update cancels active proofread/rewrite, increments a monotonically increasing generation, forces fresh analysis of the current field, and never starts an LM request while rules-only is selected. Add a narrow test seam for dispatch/generation if worker/UI Automation integration cannot be instantiated in xUnit; do not introduce a general provider factory.

- [ ] Write tests using synthetic text for the three dispatch choices; LM failure does not call Phi Silica; rules-only makes no HTTP call; an old response for identical text but a different field/generation is discarded; switching provider or pausing before rewrite completion prevents replacement. Assert that deterministic rules survive model failure.
- [ ] Run `dotnet test --project windows/Nogrammerly.Tests`; verify failures.
- [ ] Route `ScheduleProofread` and `Rewrite` by provider. Pass cancellation tokens to LM calls; use field identity **and** settings generation checks before publishing or replacing. Avoid blocking the UIA worker on HTTP; catch cancellation inside fire-and-forget tasks so it never becomes an unobserved exception. The existing replacement preview behavior is unchanged; guard the current Windows direct rewrite path, not a newly invented preview.
- [ ] Re-run Windows test projects; expect pass.
- [ ] Commit with message `feat(windows): route AI by explicit provider` when identity is available.

### Task 4: Tray settings, privacy copy and Windows smoke check

**Files:** Modify `windows/Nogrammerly/TrayApp.cs`, `README.md`, `windows/Nogrammerly.Tests/WindowsTests.cs` if UI-independent helpers are extracted.

**Interfaces:** Tray UI selects `Phi Silica`, `LM Studio`, or `Rules only`; an `LM Studio settings…` action edits base URL/model ID and offers `/v1/models` test/discovery (a text model ID entry suffices; no model-manager UI). Settings changes call `assistant.UpdateSettings(settings)`; menu displays selected provider and disconnected/error state. No network call when merely opening the menu.

- [ ] Add focused tests for UI-independent validation/copy selection if needed; record manual tray acceptance steps for each provider and offline/error states in the Windows README.
- [ ] Run new tests and confirm any new failing tests fail first.
- [ ] Implement the smallest WinForms dialog/menu additions. Clearly warn that LAN HTTP sends edited text unencrypted over the network and revise `Welcome`'s unconditional “Nothing you type leaves this PC.” Keep existing Phi Silica setup prompt available when chosen.
- [ ] On Windows run `dotnet test --project windows/Nogrammerly.Core.Tests`, `dotnet test --project windows/Nogrammerly.Tests`, and `dotnet publish windows/Nogrammerly -c Release -r win-x64`; expect green. Run manual smoke with a real LAN LM Studio only if an endpoint is available: select provider, discover model, proofread, rewrite, pause, disconnect, reconnect, verify error state and no cross-provider fallback. If unavailable, report the real-LAN smoke as **not run**, not passed.
- [ ] Commit with message `feat(windows): expose LM Studio settings and privacy status` when identity is available.

## Handoff

Implement on a feature branch; run Windows GitHub Actions for PR verification (local Linux lacks Swift and .NET SDK in the planning environment). Do not push directly to `main`. The clone currently has no Git author identity; obtain a legitimate identity before commits instead of inventing one. The spec and this plan must travel with the branch.
