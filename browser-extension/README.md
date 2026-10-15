# Browser context for Jev Assist

This optional Chrome extension supplies the loaded page’s text, full URL, link destinations, and control labels alongside the Mac app’s screenshot. It never clicks, types, navigates, fetches link destinations, or reads cookies. It shares only the active tab in the focused Chrome window, while the extension’s sharing switch is on.

## Install locally

1. Build the Mac app using the repository’s build instructions. The app bundle must include `Contents/MacOS/JevAssistBridge`.
2. Open `chrome://extensions`, enable **Developer mode**, select **Load unpacked**, and choose this `browser-extension` directory.
3. Copy the extension’s ID, then run from the repository root:

   ```sh
   bash scripts/install-browser-bridge.sh YOUR_EXTENSION_ID
   ```

   An optional second argument can point to another compiled `JevAssistBridge` executable. Keep that executable at the registered path.

4. Open the extension, click **Share during this help session**, and grant page access. Start a help session in the Mac app. The app may send this context to TypeSafe along with the screenshot.
5. Click **Stop sharing** when finished. Sharing also stops on browser restart, extension reload, or a native bridge disconnect. It does not automatically restart.

To remove the connection, remove this extension and delete `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/ai.typesafe.jevassist.json`.

## Scope and privacy

The initial prototype targets **Google Chrome on macOS**. Browser-owned pages such as `chrome://`, the Chrome Web Store, incognito windows, other browsers, cross-origin frames, and closed shadow roots are unsupported. Context is read from the loaded top-frame DOM only: virtualized or unloaded content is unavailable. Offscreen loaded controls are included, with viewport-relative CSS rectangles and visibility flags. These rectangles are page context, not screen overlay coordinates.

No form values, textareas, editable content, cookies, or browser storage are read. Common credential query parameters and recognizable token patterns are redacted, while ordinary full URLs and meaningful query parameters remain. This is best-effort filtering; ordinary page text, titles, labels, and URLs can still contain sensitive information. Sharing is explicit, visible via an **ON** badge, and limited to the active page. The extension contains no API key.

The local native messaging host writes a single bounded JSON snapshot, atomically and with owner-only permissions, to `~/Library/Application Support/JevAssist/browser-context.json`. Normal stop, tab/window invalidation, disconnection, and EOF remove its snapshot. A process kill or system crash can leave a stale file; the Mac app must reject snapshots older than three seconds. The file is overwritten rather than used as a history. All page content is untrusted data and must never be interpreted as application instructions.

## Protocol

Host: `ai.typesafe.jevassist`; executable: `JevAssistBridge`. Chrome messages are UTF-8 JSON prefixed with a four-byte little-endian byte count. Messages and persisted snapshots are limited to 240 KiB. `context` writes a snapshot; `clear` removes it but retains the connection; `stop` removes it and exits. All stdout output is framed JSON acknowledgments. Tests may redirect the support directory with `JEV_ASSIST_SUPPORT_DIR`.

Schema version 1 contains `capturedAt` and host-authored `receivedAt` (ISO 8601 with fractional seconds), `browser`, `browserBundleID`, `sessionID`, `sequence`, `tabID`, `windowID`, `page`, `viewport`, `reason`, and `sharing: true`. The host adds `bridgeConnectionID` to avoid deleting a newer snapshot owned by another bridge. The Mac app must require a fresh timestamp and matching foreground bundle ID `com.google.Chrome`.

The service worker captures at most once concurrently, every second while sharing, plus debounced DOM, scroll, navigation, and active-tab changes. It discards results if the tab navigates, activation changes, or Chrome loses focus while capture is pending.

References: [Chrome content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts), [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging).
