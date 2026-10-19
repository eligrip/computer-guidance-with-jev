# Computer Guidance with Jev

A native Mac assistant that listens while you talk and highlights the next helpful control on your screen. You do every click, keystroke, and scroll.

Built for people who want help finding their way around a computer, Jev Assist works from your evolving speech and the current interface. Start a help session and talk naturally, even while you are still figuring out what you need. Jev selects context from your own words and provides visual guidance without requiring a predefined workflow or generating spoken instructions.

**This is an experimental developer prototype, built from source.** Multi-click flows and transitions between tasks can still stall or suggest the wrong control. Images and Box are experimental [TypeSafe features](https://docs.typesafe.ai/primitives/box).

## What to expect

- **Continuous guidance:** partial speech and screen changes trigger fresh checks during your help session.
- **A steady highlight:** the box stays until meaningful screen content, layout, or the foreground window changes. A click, more speech, a timer, or a low-confidence reply alone cannot remove or replace it. Stopping the session clears it.
- **Mac and browser context:** capture covers the active app, its menus/popovers, and the visible Dock. An optional Chrome extension adds loaded page text and control descriptions.
- **You stay in control:** the app points; it never clicks, types, scrolls, or runs commands on your behalf.

## Quick start

You need:

- macOS 13 or newer.
- Apple's Command Line Tools with Swift 5.9 or newer.
- A current stable Rust toolchain with `cargo`.
- Python 3 for key setup, local signing, and restart helpers.
- A TypeSafe API key and an internet connection for Jev requests. Active sessions incur API usage.

Run in a terminal:

```sh
git clone https://github.com/eligrip/computer-guidance-with-jev.git
cd computer-guidance-with-jev
python3 scripts/setup-typesafe-key.py
python3 scripts/local-signing.py setup
./scripts/build.sh
./scripts/run.sh
```

The build creates `dist/JevAssist.app`; the last command opens it. Key setup hides your input and saves `TYPESAFE_API_KEY` to the ignored, owner-only `.env.local`. Skip that setup command if you already have the file. Keys saved through the app's settings use macOS Keychain.

Local signing gives development builds a stable identity so macOS can retain permissions between rebuilds. Keep the ignored `.local-signing/` directory private and reuse it.

### Start your first help session

1. Choose **Start help session**. If needed, follow setup for **Screen access**, **Accessibility**, and **Voice**. Granted permissions are skipped; the app rechecks when you return from System Settings.
2. Once setup is ready, choose **Start help session**, then open the app you want help with.
3. Say what you are trying to do—for example, “I'm trying to find the attachment in this email.” Follow a useful highlight yourself and keep talking as needed. You can also type into the session panel.
4. Choose **Stop help session** to end capture and transcription and clear the highlight. The menu-bar icon opens the session controls.

## Settings and context

| Control | What it does |
| --- | --- |
| **Hearing you / Earlier conversation** | Shows current speech separately from earlier context. |
| **Keeping in mind** | Shows context selected verbatim from your words. |
| **Your notes** | Opens `~/Library/Application Support/JevAssist/user_notes.md` for preferred apps, recurring tasks, or vocabulary. Notes are request context; the app does not silently write inferred facts into them. |
| **Highlight style** | Choose Soft outline (default), Corner guides, or Underline. Restyling keeps the target in place. |
| **Settings → Guidance pace** | Fast (default) allows six concurrent target requests; Balanced allows one. Both continue checking while a highlight is held and honor provider backoff. |
| **Settings → Box checks** | Single check is the default. Three checks experimentally combines overlapping boxes from three simultaneous calls. Agreement is not proof of accuracy. |

Screenshots work without an extension. For richer Chrome context, follow the [browser setup guide](browser-extension/README.md). Sharing is explicit and limited to the active loaded page in the focused Chrome window. The extension contains no API key and does not fetch link destinations or search the web.

## Privacy and local recordings

During an active help session:

| Data | Where it goes |
| --- | --- |
| Active-window and visible-Dock images, speech **as text**, selected context, personal notes, and available browser/accessibility context | Directly to TypeSafe for guidance. |
| Microphone audio | Stays on the Mac with the default **On-device only** recognition mode. Explicitly choosing **Allow Apple online recognition** may send audio to Apple. Audio is never sent to TypeSafe. |
| API key | Loaded locally from Keychain or local configuration and passed to the Rust engine over process pipes, never in command-line arguments or the extension. |

**Session recording defaults on when running from a developer checkout**, and off elsewhere. Change **Settings → Save session recordings on this Mac** before a session if needed. A visible indicator marks active recording.

Recordings save request screenshots, conversation text, selected context, decisions, timing, and highlight events under `~/Library/Application Support/JevAssist/recordings`. They contain no raw microphone audio or API credentials. Storage uses owner-only permissions and is capped at 256 MiB per session, 1 GiB overall, and 20 sessions; older recordings are pruned.

To review a recording, choose **Open recordings**, open a run's `review.html`, and select its `events.ndjson`. Keep those files and `frames/` together. Replay works offline. Screenshots, transcripts, recordings, personal notes, credentials, and signing material must stay out of Git and public bug reports.

## How it works

The **Swift native shell** handles speech, permissions, capture, screen coordinates, scheduling, and the highlight. The **Rust engine** handles Jev HTTP calls, exact source-text selection, typed decisions, and probability validation. They communicate through local process pipes, without a local web server.

The engine uses `jev-1.14.0`. A [Box question](https://docs.typesafe.ai/primitives/box) locates a useful target, while a separate presence question gates whether to use it: Box returns coordinates even when the target is absent. Code validates responses and maps normalized image coordinates back to macOS screen points. Results from old screens or stopped sessions are discarded, and fresh replies cannot move an already-held box on an unchanged screen.

Captured page content is evidence, never executable instructions. Concurrency is bounded, and rate limits or temporary provider failures trigger shared backoff. Actual responsiveness depends on capture, transcription, network latency, and service availability; request scheduling rates are not end-to-end latency guarantees.

| Location | Responsibility |
| --- | --- |
| `Sources/JevAssist/` | Native app, speech, capture, overlay, and session scheduling |
| `Sources/JevAssistCore/` | Rust process adapter, shared types, source tracking, and highlight latch |
| `engine/` | Rust Jev integration and source-span selection |
| `Sources/JevAssistBridge/`, `browser-extension/` | Optional Chrome native messaging bridge and page collector |
| `Tests/`, `scripts/` | Synthetic tests, build/setup helpers, and diagnostics |

## Development

Run these checks from the repository root. Node.js is needed for the browser and recording tests; CI uses Node 22.

```sh
cargo test --manifest-path engine/Cargo.toml --locked
bash scripts/test-core.sh
node --test Tests/browser-extension.test.mjs
node scripts/test-recording-review.cjs
./scripts/restart.sh --self-test
```

The standalone core harness works with Command Line Tools. Full Xcode also supports `swift test --disable-sandbox`. The [macOS CI workflow](.github/workflows/checks.yml) includes the full suite, a signed build, native coordinate checks, and bridge protocol tests. Use synthetic fixtures; keep private screen and speech data local.

To prepare an update while keeping an existing demo running:

```sh
./scripts/build.sh --stage
.build/next/JevAssist.app/Contents/MacOS/JevAssist --self-test
./scripts/restart.sh --dry-run
```

This builds separately under `.build/next/` and previews the restart without replacing or stopping the installed app. When ready, run `./scripts/restart.sh` or double-click **Restart Jev Assist.command**. The helper verifies signing compatibility, installs a newer staged build, retains a backup, and reopens `dist/JevAssist.app`. A normal in-app **Restart** or **⌘R** restarts without compiling.

For opt-in live checks and measured synthetic experiments, see the [evaluation guide](engine/evals/README.md). Live checks use your API key and incur usage; synthetic results do not establish real desktop accuracy or microphone-to-highlight latency. Physical multi-monitor behavior, permission-dependent capture, and complex workflows still need hands-on validation.

## Troubleshooting

- **Local speech model unavailable:** open **Settings → Advanced speech**, set up macOS Dictation for the same language, allow the assets to prepare, then choose **Check availability again** and **Apply and retry microphone**. Online recognition requires an explicit saved choice.
- **Permission enabled but still unavailable:** restart after granting access. If an earlier build used a different signing identity, quit the app, remove only its entry from the affected macOS permission list, and add `dist/JevAssist.app` again. Preserve `.local-signing/` for future builds.
- **Highlight does not advance:** it is held until meaningful screen change is detected. Task continuity and small interface changes remain areas of active iteration; a stalled highlight does not by itself show that transcription or the API is slow.

For bug reports, [open an issue](https://github.com/eligrip/computer-guidance-with-jev/issues) with your macOS version, reproduction steps, and a synthetic example where possible. Review [AGENTS.md](AGENTS.md) before changing guidance behavior.

## License

No project-wide license is currently included in this repository.
