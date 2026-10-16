# Computer Guidance with Jev

A native Mac prototype that listens while you talk through what you want to do and highlights a helpful control on your screen. You do every click, keystroke, and scroll.

There is no required goal-setting step or scripted task flow. Jev interprets your evolving speech and the current interface. It intermittently picks a passage from your own words to retain as a goal anchor.

**A highlight stays put until the screen meaningfully changes.** Speaking more, clicking without changing the interface, a slow request, or a new model response cannot erase it. Stop the help session to clear it explicitly.

## Run on your Mac

Requires macOS 13 or newer, Swift 5.9+ from Apple's Command Line Tools, and a current stable Rust toolchain (`cargo`). The native shell has no third-party Swift dependencies; the Rust engine's dependencies are pinned in `engine/Cargo.lock`. Speech settings let you choose a language and either on-device-only recognition or opt into Apple's online recognition. Typed input is also available.

```sh
git clone https://github.com/eligrip/computer-guidance-with-jev.git
cd computer-guidance-with-jev
python3 scripts/setup-typesafe-key.py
python3 scripts/local-signing.py setup
./scripts/build.sh
./scripts/run.sh
```

The setup helper reads the API key without echoing it and writes an ignored `.env.local` with owner-only permissions. The app can read that file in this checkout; a key entered in the app's settings is stored in macOS Keychain. Never put a key into the browser extension.

1. Choose **Start help session**. If setup is needed, the app walks you through three groups: **Screen access**, **Accessibility**, and **Voice**.
2. Follow the single next-step button. Already-granted access gets a checkmark. Voice combines microphone access, speech permission, and local Dictation setup. Setup stays in the main window so it cannot block macOS’s **Quit & Reopen** action. The app checks automatically when you return from System Settings and resumes setup after a required restart.
3. When all three are ready, choose **Start help session**, open the app you want help with, and talk naturally.

You can also type a thought into the panel. The menu-bar icon opens session controls; **Stop help session** ends capture and transcription and removes the box.

**Highlight style** offers three native vector previews: Soft outline (default), Corner guides, and Underline. A style change redraws the current target without moving it or resetting the highlight latch.

### Speech setup and recovery

Normal setup uses the **Voice** step, with no provider or language choices to navigate. **Settings → Permissions** reopens the three-step guide. **Settings → Advanced speech** lets you change the spoken language or recognition mode when needed. **On-device only** is the default. Apple can report its recognition service as available even when its on-device model is unavailable to this app. That is a language/model availability check, not a claim that your Mac cannot transcribe speech.

If the local model is unavailable, open **macOS Dictation settings**, enable Dictation, and select the same language under Keyboard → Dictation. Allow time for Apple to prepare the language assets, then use **Check availability again** and **Apply and retry microphone**. The app checks the actual speech API capability; it does not assume enabling Dictation guarantees that the assets are ready.

On a development Mac running macOS 14.5, enabling English (US) Dictation changed `supportsOnDeviceRecognition` from false to true and made the synthetic local transcription check pass. See [Apple’s Dictation setup instructions](https://support.apple.com/guide/mac-help/mh40584/mac).

**Allow Apple online recognition** is an explicit alternative; audio may then be sent to Apple. The setting is saved only when you click **Save speech settings** or **Apply and retry microphone**. Retrying during a help session preserves the conversation and guidance. The settings also link to microphone and speech permissions.

Before testing permissions on your development Mac, run `python3 scripts/local-signing.py setup` once, then rebuild. This creates a stable local signing certificate in an ignored, owner-only `.local-signing` directory. The helper uses an isolated password-protected keychain, temporarily adds it to the signing search list, and restores that list afterward. It does not change certificate trust or macOS permissions. Future builds reuse this identity so their designated requirement remains stable. Keep this directory between builds; its private material must never be committed or shared.

Switching from an earlier ad-hoc build may require one final permission refresh. Setup offers **Restart Jev Assist** to apply Screen Recording changes, and keeps restart available after permission repair. If a switch is on but access remains unavailable after restarting, macOS may still hold the previous build’s signing requirement: quit Jev Assist, remove only its entry from the affected permission list, and add `dist/JevAssist.app` again. Toggling an old entry off and on does not always replace that requirement. Completed permissions always skip ahead automatically. Without a local identity, builds remain ad-hoc and print a warning that permissions may not survive changes. For distribution, use an Apple-issued identity through `JEV_ASSIST_SIGNING_IDENTITY`.

## Browser context

Screenshots work without a browser extension. For richer Chrome page context, load the companion extension and install its local native messaging bridge using the [browser setup instructions](browser-extension/README.md).

The extension provides the active page's URL, loaded text, and control/link descriptions, including visibility and position. It does not fetch arbitrary URLs, search the web, bypass logins, or claim access to unloaded page content. Browser context is optional and expires quickly when sharing stops or the page loses focus.

## Personal notes

The **Your notes** button opens:

```text
~/Library/Application Support/JevAssist/user_notes.md
```

Add preferred apps, recurring tasks, or vocabulary such as what you mean by “my email.” These notes are included in guidance requests during an active session. They are editable local context, not model training. The prototype selects session goals automatically but does not silently write inferred facts into your personal notes.

## How it works

A Rust engine handles Jev requests, verbatim goal selection, and answer validation. A thin Swift shell handles macOS speech, screen capture, permissions, and the overlay. They communicate over private process pipes; there is no local HTTP server. The engine reuses its HTTP client and handles goal and guidance requests concurrently.

- **Speech:** Apple's speech recognizer streams partial transcripts in your selected language. On-device-only mode keeps audio local; online recognition is an explicit alternative. Revisions replace provisional words, rather than duplicating them.
- **Observation:** the app captures the active external window, its menus/popovers, and the visible Dock on the same display. With no foreground window, it can capture the visible Dock alone. Other apps, wallpaper, and its own highlight are excluded. Separate Dock samples detect icon layout changes; a hidden Dock cannot supply visible targets until the user reveals it.
- **Guidance:** `jev-1.14.0` receives recent speech, the goal anchor, notes, current screenshot, and available browser/accessibility context. A Box question locates the next useful target; a Noul question checks whether a useful target is visible.
- **Goal anchor:** a separate, intermittent Choice request selects an exact passage from the transcript, keeps the previous anchor, or clears it. The app never asks Jev to generate goal text.
- **Presentation:** a deterministic latch accepts a box for the current screen generation. Responses from old screens and stopped sessions are discarded. Further responses cannot move the box on the unchanged screen.
- **Scheduling:** partial speech schedules fresh evaluation immediately. The newest context is evaluated again as soon as a guidance request finishes, with one guidance request in flight. A 160 ms observation loop catches screen changes. Goal inference is separate, so it does not block pointing. Rate limits and temporary service failures trigger backoff.

Images and Box are experimental TypeSafe features. Confidence thresholds and screen-change sensitivity are prototype defaults; they need evaluation on actual desktop tasks. A presence judgment does not prove the returned box is the correct action.

### From Jev's box to your screen

Each screenshot retains the captured surfaces' combined position and size in macOS screen points, plus any image padding. For a normalized horizontal edge `u`, the screen coordinate is `captureX + ((u - paddingLeft) / contentWidth) * captureWidth`; vertical edges use the same calculation. The overlay then converts the top-origin screen coordinates to AppKit's bottom-origin coordinates. Retina pixels never get mistaken for screen points. Window moves and Dock/layout changes invalidate earlier requests.

Native self-tests check padding, image limits, coordinate scaling, and a display placed above and left of the primary screen. Physical multi-monitor and live permission-dependent capture still need hands-on testing.

## Data boundaries

During a help session, the current external window and visible Dock image, recent speech **as text**, selected goal, notes, and available interface context are sent directly to TypeSafe. Audio stays on the Mac in the default on-device-only mode. If you explicitly allow Apple online recognition, audio may be sent to Apple for transcription; audio is never sent to TypeSafe. Screen images and transcripts are not written to logs or saved as recordings. The optional extension writes only its latest context to a local file with restricted permissions.

The app never clicks, types, scrolls, or runs commands on your behalf. Page content is treated as evidence, not executable instructions. A browser page may contain sensitive text, so only start sharing a page you intend to use with the assistant.

## Development and verification

```sh
cargo test --manifest-path engine/Cargo.toml --locked
bash scripts/test-core.sh
node --test Tests/browser-extension.test.mjs
./scripts/build.sh
dist/JevAssist.app/Contents/MacOS/JevAssist --self-test
JEV_ASSIST_BRIDGE_TEST_BINARY="$PWD/dist/JevAssist.app/Contents/MacOS/JevAssistBridge" python3 Tests/browser-bridge.test.py -v
```

The tests cover highlight persistence, stale responses, session boundaries, exact goal selection, API payloads, malformed output, Rust process reuse, cancellation, and restart. Native checks cover image preparation and screen coordinates. Browser bridge tests use temporary directories and synthetic messages. With full Xcode installed, `swift test --disable-sandbox` also runs the XCTest suite; Command Line Tools alone may lack XCTest. GitHub Actions runs the full suite on macOS.

To verify an installed English (US) speech model on your Mac, run `swift scripts/check-local-speech.swift`. It synthesizes a fixed sentence into a temporary file and transcribes it with on-device recognition required. It never opens the microphone, sends a Jev request, or opts into online transcription. Run it outside restrictive process sandboxes so it can reach Apple’s speech service; it is intentionally separate from CI because local speech assets must already be installed.

An optional live check sends three synthetic requests, without capturing your screen or reading personal notes:

```sh
python3 scripts/smoke-jev.py --live
```

It verifies a visible Box, an absent-target presence judgment, and verbatim goal selection. It uses your key and incurs API usage. Passing this check verifies connectivity and a small fixture; it is not a desktop accuracy benchmark.

After building the engine, run `bash scripts/smoke-native.sh --live` to exercise the full Swift → Rust → Jev path against a generated photo-saving interface. This makes two synthetic requests and checks that the box points to the expected button.

## Source layout

```text
Sources/JevAssist/             Native app, speech, capture, overlay, scheduling
Sources/JevAssistCore/         Rust process adapter, shared types, highlight latch
engine/                       Rust Jev engine and exact source-span selection
Sources/JevAssistBridge/       Local Chrome native messaging host
browser-extension/            Optional active-page context collector
Tests/JevAssistCoreTests/      Deterministic core tests
scripts/                      Build, launch, key setup, and synthetic API check
```

The project uses the installed [TypeSafe skill](.agents/skills/typesafe-ai/SKILL.md). See [Box](https://docs.typesafe.ai/primitives/box), [images](https://docs.typesafe.ai/images), and [source-value extraction](https://docs.typesafe.ai/cookbooks/pre_parsed_value_extraction_cookbook) for current API details.

The [Jev Voice Turn experiment](https://github.com/dabit3/jev-experiments/tree/main/jev-voice-turn) informed partial-transcript scheduling and coalescing. This app uses screen freshness and visible-target judgments to guide continuously; it does not require a completed spoken turn before pointing.
