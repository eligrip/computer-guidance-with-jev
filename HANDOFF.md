# Session handoff — October 19, 2026

## Later implementation update — October 19, 2026

The user resumed the multi-click improvement request. The changes below are now
implemented in the current source and built into the locally installed app.
The older investigation/proposal sections below are kept
as historical context and no longer describe the complete current source.

- Rust now supports `intent`, retaining legacy `goal`. A single HTTP call asks
  independent Choice questions for immediate substantive focus and the broader
  task. Both select exact source text. The full validated latest utterance is
  current evidence, so a trailing generic question cannot hide its concrete task.
- Guidance receives `task_anchor` alongside immediate focus. Its questions advance
  from the visible screen, including already-selected checkboxes and open dialogs.
  The Swift panel's Keeping in mind uses the task, and local replay stores both.
- `IntentResponseOrder` applies paired selections atomically with source identity,
  response order, previous-anchor and current-utterance validation. Same-utterance
  recovery can select a concrete span preceding generic focus. Cancellation retires
  previously heard source slots, including unselected substeps; new repeated words
  remain eligible. Initial abstention must not retire a growing partial's prefix.
- The native observer watches the actual highlighted AX control (bounded hit-test
  plus parent lookup) for value/selected/expanded/enabled changes. An observed state
  change settles for 120 ms and releases the latch even if the screen thumbnail
  misses a checkbox tick. Failed reads, focus/caret/hover and clicks alone do not
  release it. The observer resets prepared-image and AX caches on accepted change.
  Full AX label context also carries these observed states. Without AX support the
  existing visual scene detector remains in use. Real browser AX behavior has not
  been exercised in a live help session in this turn.
- A broader regression exposed a cancellation false target: presence scored a
  Go back control at 0.71 after spoken cancellation. Guidance now asks a separate
  `request_active` Noul in the same call. Each sample must meet both activity and
  presence thresholds (existing configurable presence threshold, default 0.65)
  plus Box confidence. These probabilities are not multiplied. Raw activity is
  retained in single/consensus diagnostics and local replay. Cancellation still
  cannot clear a held box on unchanged screen content.
- Image-size test assertions now use the actual 280-pixel minimum.

New files: `Sources/JevAssistCore/IntentResponseOrder.swift`,
`ControlStateChangeDetector.swift`, and `engine/evals/multistep_guidance.py`.
The evaluation makes 14 bounded calls (13 assertions), with generated cookie
screens and invented speech only. `--baseline --engine <old-binary>` exercises
legacy goal behavior. An unchanged baseline copy and synthetic reports are in
ignored `.build/evals`, never private screenshots or real microphone capture.

Validation in this turn:

- Rust: 65 passed, 3 opt-in live tests ignored. Loopback tests need sandbox
  escalation; sandbox binding failures are not application regressions.
- Standalone Swift core: 238 checks passed. Native app self-test: 204 passed.
- Offline recording/replay checks passed, including independent task context and
  backward compatibility with older recordings.
- Live multistep baseline: 12/13; selected the generic question over the concrete
  task. All baseline synthetic screen targets already passed. Final: 13/13,
  including task switches, substeps, cancellation, repeated requests, checkbox
  before/after, and visible completion abstention. Screen calls took 200–388 ms
  in the final small run.
- Existing live utterance regression: final 17/17. The cancellation example had
  presence 0.72 and activity 0.01, correctly withholding its Box.
- `scripts/build.sh --stage` produced a signed bundle, whose native self-test
  passed; restart dry-run verified signing compatibility. The stopped installed
  app was updated with `scripts/restart.sh`, preserving the normal backup.
  Native UI verification showed Ready when you are and Start help session, with
  no permission/setup block; no help session was started.

No live microphone/help session was started and no real browser cookies were
changed. These tests do not prove acoustic latency, native AX coverage across
browsers, or a sustained-throughput rate for the new questions. Preserve hands-on
iteration and inspect local recordings if the next real flow still stalls.
The README received an independent documentation commit during this turn;
its new structure was preserved and current implementation notes added.

---

This is the continuity document for the next agent. Read [AGENTS.md](AGENTS.md), this file, and [README.md](README.md) before changing the application. This document distinguishes shipped behavior, investigation findings, and proposals that have **not** been implemented. It deliberately excludes private screen contents, raw transcripts, credentials, and signing material.

## Where work stopped

The user first requested another implementation iteration:

> “ok getting better, but still getting stuck between tasks, multi click tasks (like clearing cookies which requires three clicks), etc. Keep iterating and improving and do so in the context of Jev's advantages”

The user then replaced that immediate task with:

> “actually just write down all of the context from this session in the repo for another agent to take off from here”

Consequently, this handoff is documentation only. Do not mistake the proposed work below for shipped fixes.

- Repository: [eligrip/computer-guidance-with-jev](https://github.com/eligrip/computer-guidance-with-jev), public as requested. Display name: **Computer Guidance with Jev**; native app/bundle: **JevAssist**.
- Local checkout: `/Users/eligripenstraw/Jev-Assist`, branch `main`.
- Last implementation commit: `0da254a9f6bb6c2e085e21afb7bd3075e69de3fd` — “Fix incomplete browser capture and keep guidance on current speech.”
- The working tree was clean before writing this handoff. No Rust `intent` operation, Swift task anchor, or multi-step evaluation has landed.
- Earlier delegated investigations used agents named `guidance_core`, `native_app`, and `browser_bridge`. **No child agents were active when the handoff was written.** Do not wait for them or assume their assignments produced files.
- The last completed implementation turn installed/restarted the app and verified its ready screen. This handoff did not rebuild, restart, stop, or start a help session. Current process state was not reverified.
- The user wants to preserve the ability to demo the app while changes are prepared. Stage builds separately; do not overwrite a running bundle during compilation.

## What the user wants

The product helps people who struggle to use computers, particularly older users, by highlighting the next helpful control while they talk naturally. The user is the initial tester. Initial platform is **Mac plus browser**. Example tasks explicitly discussed: find an email attachment, join a video call, download a document, and now a multi-click cookie-clearing flow.

The interaction is a user-started help session with proactive, continuous guidance inside it. The user does not have to declare a precise goal, signal confusion, or wait for a completed speech turn. Keep listening to partial speech and using current screen evidence to help them move forward. The assistant points; the person performs every click, keystroke, and scroll.

Earlier brainstorming briefly considered fixed workflows and templated instructions. The user corrected that direction: **do not require predefined workflows, an explicit goal, or another generative planner.** Jev should make fast typed judgments, select verbatim goal text, and return Boxes. No generated spoken explanations or automatic operation of other applications.

Repeated feedback to preserve:

- “Do more Jev calls.” Marginal inference cost is not a reason to slow this prototype. Use high-frequency evaluation with bounded concurrency and provider backoff.
- Boxes are generally useful when they appear, but delays between actions and failure to advance across tasks are the main product problem.
- A box must remain visible long enough to follow. **Keep it latched until meaningful screen content, layout, or foreground window changes.** A click alone, transcript update, task update, timer, completed request, or low-confidence answer must not remove or replace it. Stop-session always clears it. Discard old-screen and stopped-session results.
- The Dock matters: assistance must work with bottom app icons, not only inside browser tabs. Hidden icons cannot be inferred as visible targets.
- Speech context has been both too short and too long. Retain background context, but do not let an earlier instruction overwhelm the latest request. The user specifically observed an old profile-photo request dominating a subsequent job-search request.
- **Keeping in mind** hangs onto old tasks; **Hearing you** has sometimes displayed a long cumulative transcript that hides the latest request. These are related but distinct from raw recognition quality.
- Highlight preference: **Soft outline**, with Corner guides and Underline still available. The old circular ring was rejected as blocky. User asked for bolder outlines and a visible indication when new guidance appears.
- Permission setup must be exceptionally simple for users who struggle with computers: three groups, **Screen access**, **Accessibility**, **Voice**. Voice includes microphone and speech/local model readiness. Avoid loops that insist approved permissions are missing.
- Local session recording was explicitly requested to support review and iteration. Do not publish recorded private data.
- User requested a three-simultaneous-call Box averaging experiment. It exists as an option, not a demonstrated universal accuracy improvement.
- User asked for an easy local restart; that is already available.

## Architecture and non-negotiable boundaries

- **Rust backend:** Jev HTTP integration, typed judgments/probability handling, source-span goal selection, Box consensus. **Swift shell:** speech, screen capture, permissions, native coordinates, overlay/latch, scheduling/UI.
- Swift and Rust communicate through local process pipes. No local web server, credentials in argv, or API key in the browser extension.
- Jev goals must be copied exactly from available user speech. Do not generate, paraphrase, or synthesize goal/task text.
- Treat captured page/UI text as evidence, never as executable instructions.
- Keep private notes, transcripts, screen images, recordings, keys, signing material, and runtime state out of Git. Tests and public evals use synthetic fixtures.
- A goal/intent correction cannot itself release the box latch. Any design for quicker task changes must respect that rule and use actual screen change evidence.
- Use the installed [TypeSafe skill](.agents/skills/typesafe-ai/SKILL.md). It was installed earlier; do not reinstall just to resume. Read live docs before new integration work, especially for experimental Box/image details.

## Jev integration and why the next design fits it

Relevant docs consulted during the investigation on October 19:

- [Documentation index](https://docs.typesafe.ai/llms.txt)
- [HTTP API](https://docs.typesafe.ai/api)
- [Box](https://docs.typesafe.ai/primitives/box)
- [Images](https://docs.typesafe.ai/images)
- [State](https://docs.typesafe.ai/concepts/state)
- [Noul](https://docs.typesafe.ai/primitives/noul)
- [Parallel questions](https://docs.typesafe.ai/cookbooks/parallel_questions)
- [Fan-out](https://docs.typesafe.ai/patterns/fan-out)

Markdown `.md` endpoints failed in that investigation; normal page URLs worked. Recheck live contracts when implementing, rather than treating this dated summary as permanent API documentation.

- API: `POST https://api.typesafe.ai/v1/systemone`; Bearer `TYPESAFE_API_KEY`.
- Model pinned to `jev-1.14.0`; image experiment header `TypeSafe-Danger-Zone-Images: true`.
- Box question has `type: "box"` and `instructions`, no `criteria`. Answer edges are normalized `top`, `bottom`, `left`, `right`, with confidence.
- Box returns coordinates even if the requested target is absent. A separate Noul presence question gates display. Current defaults: minimum presence `0.65`, minimum confidence `0.25`; these remain prototype calibration values.
- Independent questions sharing state can run together in one provider request. They cannot inspect one another's answers. This is useful for separating current-step selection from overarching-task selection without adding a serial round trip.
- Choice selects from explicit source candidates; no-match/keep-previous outcomes are important. Candidate coverage matters: the model cannot select words omitted by preprocessing.
- Multiple named images can provide before/after evidence if needed, but that was only considered, not implemented for this iteration.
- Docs read on October 19 specified a minimum image side of **280**, maximum **1568**, PNG/JPEG, 16 MiB per file, and 32 MiB multipart/expanded-image limits. Current `ScreenObserver.ImageLayout` already pads to **280**; `NativeChecks.swift` still has a weaker `256...1568` assertion. An earlier working note incorrectly suggested production was still padding to 256. The handoff-time source check corrected that assumption; do not claim a production padding fix is still needed without new evidence.

Use Jev for narrow, frequent decisions over good evidence; code owns freshness, bounded scheduling, provenance, geometry, and presentation. More calls with stale or incomplete input do not resolve missing evidence.

## What is already implemented

### Continuous scheduling and transport

`Sources/JevAssistCore/GuidancePace.swift` currently defines:

| Setting | Fast (default) | Balanced |
| --- | --- | --- |
| Concurrent single-target operations | 6 | 1 |
| Minimum target dispatch interval | 20 ms | 250 ms |
| Observation loop delay | 40 ms | 160 ms |
| Concurrent goal operations | 2 | 1 |
| Changed-speech goal interval | 120 ms | 500 ms |
| Unchanged-speech goal interval | 500 ms | 2 s |

Partial speech triggers evaluation. Slots refill when requests complete; observation is not the only inference trigger. Recent exact frames can be reused. Checks continue while a highlight is held, but cannot replace it on an unchanged scene. Goal checks continue when the session panel is foreground or capture is unavailable.

The Rust engine uses pooled **HTTP/1.1** and a shared concurrency bound of ten. HTTP/2 produced correlated failures during earlier local load comparisons. HTTP/1.1 reduced that coupling but did not eliminate all connection errors. Rate limits/temporary failures establish a shared monotonic cooldown; new/queued stale work fails promptly instead of building a backlog. A later success cannot shorten an established retry deadline. Do not remove this reliability behavior in pursuit of higher request counts.

`engine/evals/README.md` contains measured synthetic throughput. One six-target/20 ms run completed about 35 target operations/s and 43 successful HTTP calls/s including goals; target median/p95 was 150/210 ms, with two isolated failed calls out of 784 attempted. Eight targets performed worse in that small comparison. These are engine/synthetic measurements, not microphone-to-highlight latency guarantees.

### Speech and source provenance

- Apple speech recognition streams partial results; on-device-only is the default. Online Apple recognition requires explicit opt-in.
- Apple punctuation is enabled. Segment timestamps and substring ranges identify an exact current utterance after an observed pause of at least 0.8 seconds. This uses available partial results; it does not wait for a silence timer before guidance.
- A trailing word with zero duration no longer erases useful preceding timing.
- Up to 24,000 characters of conversation are retained. Current utterance/request and earlier conversation are supplied separately.
- `SessionTranscript` maintains stable word/source identities across revisions and repeated identical phrases.
- `GoalResponseOrder` rejects out-of-order/retracted/retired source selections, stale keep-previous echoes, and results attached to an older occurrence of repeated words.
- `ConversationFocus` drives the compact Hearing you display and Earlier conversation expansion.
- Current implementation has only **one goal anchor**, used for both latest actionable focus and ongoing task context. That conflation is the principal pending design issue.

### Capture, Dock, and presentation

- Capture includes the active external app's window, applicable menus/popovers, and visible Dock on the display; it excludes unrelated apps, wallpaper, and its own overlay.
- A shallow wide browser toolbar surface overlapping a large same-app page is composited with the page. Previously, choosing the toolbar alone lost most of the browser content.
- The painted Dock is located inside its potentially display-sized transparent backing surface. Every third target request can use a closer Dock crop with independent mapping/fingerprint. Dock-only capture is possible without a foreground window.
- Mapping retains screen-point geometry and normalized padding. Retina pixel sizes are not treated as screen points; top-origin capture coordinates convert to AppKit coordinates.
- Prepared JPEG reuse is bounded to 500 ms and exact geometry/fingerprint equality; hits do not extend the deadline. Observation/validation avoid encoding JPEGs unnecessarily.
- Raw accessibility observations are shared between app/Dock views, cached for at most one second. Current app evidence is mostly labels; Dock items also have mapped bounds.
- Scene change detection uses 128×80 grayscale fingerprints with separate primary/Dock evidence and a 120 ms localized-change settling period. Its pending deadline is not reset on every sample. Broad content/identity changes advance immediately.
- Tiny hover/caret/badge changes intentionally do not release the latch. Whether small but meaningful checkbox/menu-state changes are being missed needs investigation.
- Default Soft outline is already a **5.5-point teal border** with contrasting edges. Each accepted new box gets one **0.85-second arrival halo**; Reduce Motion skips the animation. The steady outline remains.

### Three-call experiment

Single check remains default. Three checks sends the same state/image/questions in three simultaneous calls. After gating, boxes are confidence-weighted only when selected boxes agree pairwise at IoU ≥0.5. If all three disagree, the strongest agreeing pair can be used; no pair means abstention. Fast permits two three-call batches, Balanced one. Agreement is not treated as independent evidence or multiplied confidence.

Replay retains individual samples, probabilities, selected indices, final box, and method. Synthetic results showed mixed boundary precision and correlated/identical answers. Do not describe three calls as proven to be faster or more accurate.

### Permissions and restarts

Earlier failures were not solved by repeatedly showing permission prompts. macOS retained old signing requirements and the setup UI could interfere with Quit & Reopen. Fixes include stable local signing, inline setup, automatic rechecking/skipping granted steps, and reliable restart recovery.

On this Mac, enabling English (US) Dictation changed Apple's `supportsOnDeviceRecognition` from false to true and enabled the synthetic local speech check. The user explicitly approved enabling Dictation and accepting Apple's system disclosure. The app still defaults to requiring local recognition. Do not ask again merely to repeat that completed setup, and do not opt into online recognition implicitly.

Existing `.local-signing` material must be preserved. Reuse the build helper's identity; do not regenerate it casually, reset all TCC permissions, or reintroduce a setup wizard loop. Advanced speech settings remain available for troubleshooting while the normal path stays simple.

Restart options already available: main-panel **Restart**, **⌘R**, root **Restart Jev Assist.command**, or `bash scripts/restart.sh`. Restart alone does not compile.

### Notes, browser context, and recordings

- Editable notes: `~/Library/Application Support/JevAssist/user_notes.md`. Included as context, not model training. No silent inferred-fact writing.
- Optional Chrome extension supplies active loaded page URL/text/control descriptions through native messaging. It does not web-search, fetch arbitrary URLs, bypass logins, or claim access to unloaded page content. Sharing expires when no longer current. See `browser-extension/README.md`.
- Developer checkout recordings default on during active help sessions. Location: `~/Library/Application Support/JevAssist/recordings`.
- Records images sent to Jev, text context, goals, decisions, timing, highlight/suppression reasons, and text-free recognition timing. No raw microphone audio or API keys.
- Limits: 256 MiB/session, 1 GiB overall, 20 sessions; owner-only files; async writes; identical images deduplicated.
- Each run has `review.html`, `events.ndjson`, and `frames/`. Viewer is local/offline; choose the NDJSON file to replay. Keep private files outside tracked repo paths.

## Latest investigation: evidence and uncertainty

The prior investigation reviewed the latest available stopped recording from **October 18**, approximately 229 seconds long, with about 7,484 events: 2,907 frame events, 2,907 decisions, 1,066 goal events, 225 speech-recognition events, 111 highlights, and 261 context events. These counts are reported from that investigation, not freshly rerun for this documentation change. Locate recordings locally by date; no private recording contents are copied here.

Concrete finding reported by `guidance_core`:

- Around 199 seconds, a generic 17-character help question replaced the task-specific goal even though the current utterance also contained the actual cookie-clearing request.
- The generic focus remained until the user restated the task around 216 seconds.
- Goal request timing was fast in that sample: median approximately 121 ms, p95 approximately 264 ms. This particular stall was evidence of context/selection loss, not slow goal inference.
- `goals::speech_context_with_utterance` promotes the newest candidate clause to current request. A generic trailing question can therefore demote the concrete task into background. Candidate filtering relative to a newer selected goal can also prevent recovering an earlier task span in the same utterance.

Do **not** generalize that finding into a claim that all latency is solved, or that raw ASR accuracy is proven good. The pipeline has separate possible bottlenecks: acoustic recognition, partial callback delay, context construction, candidate coverage, goal choice, screen-change detection, capture, network/backoff, freshness suppression, and display acceptance. Existing synthetic latency excludes several of them.

Other audit hypotheses were not yet resolved:

- A small checkbox state or submenu change may be semantically meaningful but fall below the coarse fingerprint threshold.
- Accessibility context currently lacks useful selected/checked/enabled/value state for many app controls. Richer observed evidence may help avoid repeating a completed substep.
- A recently opened menu/dialog may be missing from selected capture surfaces in some cases. The earlier shallow-toolbar bug was fixed, but new menu cases need evidence.
- A retained high-level task plus the current screen may be sufficient for multi-click progress; before/after evidence or a typed progress judgment should be added only if testing demonstrates the need.

## Proposed next implementation — NOT DONE

The direction discussed was to separate **what the user is trying to accomplish** from **the immediate request/step**. This must improve continuity without recreating stale-goal persistence.

### Rust scope

1. Add a new pipe operation `intent`, leaving existing `goal` compatibility intact for tests/evals.
2. Proposed input: `transcript`, `current_utterance`, `previous_goal`, `previous_task`.
3. One provider request asks two independent Choice questions over shared state: latest actionable step/focus and overarching current task. Proposed result: `{ "goal": <exact source text or null>, "task": <exact source text or null> }`.
4. Task selection preserves the broader request through within-task substeps or generic help questions, but switches promptly on an unrelated new task and clears on cancellation/completion expressed by the user. Both outputs must resolve to exact source spans or valid retained anchors.
5. Include the **full latest utterance** as named evidence for both intent and guidance. Do not privilege only a trailing generic clause.
6. Add optional `task_anchor` to guidance input. Latest explicit request has priority; task supports interpreting the next visible step. Do not introduce fixed workflows, a generated plan, or model-written explanations.
7. Ensure task candidates are not accidentally filtered out by the immediate-step source floor. Candidate/provenance policies for task and step may need to differ.
8. Preserve strict response validation, no-match behavior, concurrency bounds, and stale-response protections.

Files expected to change: `engine/src/models.rs`, `engine/src/client.rs`, likely `engine/src/goals.rs`, plus synthetic tests. None changed before this handoff.

### Swift integration scope

1. Add a typed `IntentSelection` and `inferIntent(...)` adapter; retain `inferGoal` for compatibility if useful.
2. Add separate task-anchor state alongside current goal. Consider showing task in Keeping in mind while Hearing you follows current utterance/focus. Avoid making the UI more complicated.
3. Carry previous task and previous goal snapshots with each request. Apply source/order validation to both, including stale keep-previous echoes, recognition revisions, repeated identical phrases, cancellation, and out-of-order parallel results.
4. Do not blindly reuse a monotonic immediate-goal source floor for overarching task recovery; cover the concrete-task-plus-generic-follow-up failure.
5. Include task context in guidance requests and local replay/recording. Ensure stale results cannot revive an old task after switching or cancelling.
6. A context update may trigger fresh inference but must not clear/replace a held highlight on an unchanged screen.

Expected files: `Sources/JevAssistCore/Models.swift`, `JevClient.swift`, provenance helpers/tests, `Sources/JevAssist/SessionController.swift`, `JevAssistApp.swift`, and recording models/viewer as necessary. None of these proposed edits landed.

### Native observation scope

Audit the actual transition before changing thresholds. Consider target-local visual evidence or structured accessibility state for checked/selected/enabled controls. A click alone is not evidence that a task advanced. Do not fix a stalled checkbox by adding a timer that removes the box. Test menu/dialog/checkbox changes while preserving immunity to caret blinks and hover effects.

One narrow follow-up is to tighten the native image-limit assertion from 256 to 280, since production padding is already 280. This is separate from the task-continuity problem.

### Evaluation scope

A proposed `engine/evals/multistep_guidance.py` and synthetic fixture generator were assigned but **do not exist** in the checked working tree.

Build a generated 3–5-screen cookie-clearing sequence, with expected next targets at each screen, and a visible completion state. Keep the same high-level spoken request across screen changes. Add a generic follow-up, a within-task substep, a new unrelated task, and cancellation. Measure correct next-target selection, abstention when complete, and time to a correct answer after each synthetic scene change.

Use the existing `EnginePipe`/private key-loading helpers. Compare the current release baseline before tuning prompts, then the changed release. No live deletion of the user's browser cookies, no real microphone capture, and no private screenshots/transcripts in fixtures. Do not claim that this synthetic test proves real desktop or acoustic latency.

Suggested acceptance cases:

- A concrete request followed by “what next?” retains the concrete task.
- A relevant immediate substep changes focus without losing the overarching task.
- Menus/dialogs advance the visible target through several clicks without restating the original request.
- A checkbox's meaningful state change is detected, while hover/caret changes do not release a box.
- A new task promptly becomes relevant context; an older parallel answer cannot restore the previous task.
- Cancellation cannot be undone by stale responses; repeating the same request later is a distinct source occurrence.
- A completed visible flow does not repeatedly suggest its old action.
- Held highlights remain latched under transcript updates and low-confidence/completed calls.

## Source map for the next agent

| Area | Main files and details |
| --- | --- |
| Scheduling/lifecycle | `Sources/JevAssist/SessionController.swift`: `tick`, guidance pump, `inferGoalIfNeeded`, session IDs, scene generations, metrics, recording |
| UI | `Sources/JevAssist/JevAssistApp.swift`: Hearing you/Keeping in mind; latter currently displays `session.goal` |
| Swift pipe API | `Sources/JevAssistCore/JevClient.swift`, `RustEngineTransport.swift`, `Models.swift` |
| Rust protocol | `engine/src/models.rs`: currently `Guidance` and `Goal` only; no `Intent` |
| Jev state/questions | `engine/src/client.rs`: guidance payload, target definition, goal payload/parser, shared client/cooldown |
| Candidate construction | `engine/src/goals.rs`: clause boundaries, at most 16 recent distinct source candidates, current-utterance suffix validation, previous-goal floor, current/background split |
| Source freshness | `Sources/JevAssistCore/SessionTranscript.swift`, `GoalResponseOrder.swift` |
| Speech | `Sources/JevAssist/SpeechTranscriber.swift`, `SpeechConfiguration.swift`; `Sources/JevAssistCore/SpeechTranscriptAccumulator.swift`, `ConversationFocus.swift` |
| Capture | `Sources/JevAssist/ScreenObserver.swift`, `CaptureSurfaceSelection.swift`, `DockSurfaceGeometry.swift`, `AccessibilityObservation.swift` |
| Scene/latch | `Sources/JevAssistCore/ScreenSceneDetector.swift`, `HighlightLatch.swift` |
| Outline/arrival cue | `Sources/JevAssist/HighlightOverlay.swift`, `HighlightStyle.swift`, `HighlightAppearanceChecks.swift` |
| Recording/replay | `Sources/JevAssist/SessionRecorder.swift`, `RecordingReviewPage.swift`, `scripts/test-recording-review.cjs` |
| Setup/relaunch | `SetupCoordinator.swift`, `SetupView.swift`, `AppRelauncher.swift`, `scripts/local-signing.py`, `scripts/restart-local.py` |
| Deterministic tests | `Tests/JevAssistCoreTests/`; `Sources/JevAssist/*Checks.swift`; Rust unit/mock tests |
| Synthetic live evals | `engine/evals/utterance_focus.py`, `sustained_guidance.py`, `box_consensus.py`, `command_focus.rs`, `transport_compare.rs` |

## Build, verify, install, and recover

Local development environment at the last implementation: Apple Silicon Mac, macOS 14.5, Swift 5.10 Command Line Tools, Rust 1.98. Recheck versions if the environment changed. CLT alone lacks XCTest here; GitHub Actions has full Xcode. Do not misdiagnose unavailable local XCTest as an application failure.

Run from the checkout. Relevant commands, not a requirement to repeat every unrelated check for every change:

```sh
cargo test --manifest-path engine/Cargo.toml --locked
bash scripts/test-core.sh
node --test Tests/browser-extension.test.mjs
node scripts/test-recording-review.cjs
python3 Tests/sustained-guidance.test.py -v
python3 Tests/local-signing.test.py -v
bash scripts/restart.sh --self-test
```

Prepare the update without disturbing the demo:

```sh
bash scripts/build.sh --stage
.build/next/JevAssist.app/Contents/MacOS/JevAssist --self-test
JEV_ASSIST_BRIDGE_TEST_BINARY="$PWD/.build/next/JevAssist.app/Contents/MacOS/JevAssistBridge" python3 Tests/browser-bridge.test.py -v
bash scripts/restart.sh --dry-run
bash scripts/restart.sh
```

Stage output is `.build/next/JevAssist.app`; installed path is `dist/JevAssist.app`. The restart helper verifies signatures/identity, installs only a newer different stage, preserves a backup in `.build/restart-backups`, and reopens the established installed path. An older/equal-time stage should not replace a newer normal build. Packaging refreshes executable timestamps; manually changing them can confuse comparison, so rebuild if necessary.

Reuse `.local-signing/identity` through `scripts/build.sh`. Signing material is ignored and private. The existing `.env.local` already contains the user's TypeSafe key; do not print/source it into visible logs, put it into command arguments, or ask the user to reenter it unnecessarily. In-app key entry uses Keychain. Test/eval helpers load credentials privately and pass them to the engine over stdin.

Build/signing, loopback HTTP mock tests, and app restart may need sandbox escalation in the agent environment. Use ordinary tool approval mechanisms when required. A prior automatic review timed out and succeeded on retry; do not treat a timeout as a substantive rejection or bypass an actual rejection. Avoid new system/privacy changes merely to rerun an already-working setup.

For UI verification use the available computer-use tool and its skill; do not operate app UI via shell/AppleScript. Last verified UI was **Ready when you are** with **Start help session** available and no setup block. Starting a live microphone/capture session is not necessary for deterministic or synthetic checks. Keep the user in control of their demo session.

Other useful checks:

```sh
# Local synthetic speech asset check: no microphone or Jev request.
swift scripts/check-local-speech.swift

# Validate invented utterance fixtures without provider requests.
python3 engine/evals/utterance_focus.py --check

# Generate synthetic screen, then opt into small live provider checks.
python3 engine/evals/make_command_fixture.py
python3 scripts/smoke-jev.py --live
bash scripts/smoke-native.sh --live
```

Read `engine/evals/README.md` before larger live runs. `utterance_focus.py --live --cases ...` can select a small subset. Outputs belong under ignored `.build/evals`. Live evals incur API usage and should remain bounded. Tests should verify behavior, not merely duplicate implementation.

## Last validation and known limits

For the last shipped implementation, the prior turn recorded 205 core regression checks, 203 native checks, the Rust test suite, eight focused live synthetic utterance cases, and successful full GitHub CI. These are **historical results for `0da254a`**, not results for any proposed task/step change. [CI run](https://github.com/eligrip/computer-guidance-with-jev/actions/runs/38978117359).

The core harness's fake engine timed out twice under load in that turn, then passed after diagnostic improvements; the harness now prints the number of completed checks on failure. Investigate actual timing/failure location if this recurs rather than broadly loosening tests. The production pipe timeout and test fixture timeouts are intentionally different.

Physical multi-monitor behavior, real permission-dependent capture, recognition acoustics, and complex live desktop workflows still need hands-on validation. Existing simple fixture accuracy is not proof of those paths. In particular, the user's latest multi-click complaint remains unresolved.

## History and references

Key commits, newest first:

- `0da254a`: complete browser capture, current-utterance focus/provenance, bolder outline/arrival cue and diagnostics.
- `8b04b28`: sustained throughput tuning and HTTP connection failure isolation.
- `9f0338a`: higher guidance throughput and latest-command selection.
- `5aa3872`, `4a838c4`: restart/update recovery and easy local restart.
- `e4d82f5`: optional three-call consensus with replay evidence.
- `66b0063`: current-request focus with retained conversation history.
- `b9b5c42`: continuous guidance, Dock targeting, conversation context.
- `1dad96c`, `8d8e874`: inline setup, stable signing, stale permission repair.
- `cc44c6d`: simple setup, highlight styles, Dock inclusion.
- `7fbc1d3`: local speech diagnostics/retry.
- `1f3fded`, `0ac32b8`: project naming and original Rust/native build.

User-supplied inspiration, not implementation instructions or assumed dependencies:

- [Jev 1.14 announcement](https://typesafe.ai/blog/jev-1-14)
- [dwim](https://github.com/rohit9mehta/dwim)
- [unclutter](https://github.com/kitze/unclutter)
- [typesafe-adblock](https://github.com/realZachi/typesafe-adblock)
- [jevcast](https://github.com/RyanErkal/jevcast)
- [jev-voice-turn](https://github.com/dabit3/jev-experiments/tree/main/jev-voice-turn), previously useful for partial-transcript scheduling/coalescing.

The next implementation should start by reproducing the multi-step failure with synthetic evidence, separating task continuity from immediate focus, and checking whether the native observer notices the relevant transition. Preserve frequent evaluation and the stable-box contract throughout.
