# Apple Intelligence setup for the iOS Simulator

The chat feature in `FoundationForms` uses Apple's on-device `FoundationModels` framework. For it to actually respond (not just compile), the language model assets have to be downloaded and reachable. On the iOS Simulator that means **the host Mac** has to have Apple Intelligence enabled — the simulator does not download its own copy of the model.

## Why this is needed

`FoundationModels` has two layers:

1. **Framework binding.** When the app launches, `SystemLanguageModel.default.availability` reports `.available` as long as the framework is linked and the OS knows about Apple Intelligence. The chat UI renders the input bar based on this signal.
2. **Model assets.** When you actually call `streamResponse(to:)`, the system loads the on-device model weights and a separate input/output safety model (`com.apple.fm.language.instruct_300m.safety`). On the simulator, both are read from the host Mac's asset catalog (`com.apple.modelcatalog`), not from the simulator itself.

If the host Mac hasn't downloaded those assets, the framework still says `.available`, but generation fails. You'll see logs like:

```
Model Catalog error: Error Domain=com.apple.UnifiedAssetFramework Code=5000
"There are no underlying assets ... for asset set com.apple.modelcatalog"
End sanitizeText with error: ... com.apple.fm.language.instruct_300m.safety ...
LanguageModelSession.GenerationError error -1
```

The chat bubble will read *"The on-device model isn't ready..."* — that's `ChatViewModel` mapping `LanguageModelSession.GenerationError.assetsUnavailable` to a friendly message.

## Requirements

- An **Apple Silicon** Mac (M1 or later). Foundation Models are not available in the simulator on Intel Macs.
- macOS 26 or later on the host.
- A region/language combination that Apple Intelligence currently supports.
- Several GB of free disk space — the foundation models are a one-time download.

## Enable Apple Intelligence on the host Mac

1. Open **System Settings** on the Mac.
2. Go to **Apple Intelligence & Siri**.
3. Toggle **Apple Intelligence** on.
4. Wait for the foundation models to finish downloading. Progress is shown in the same panel. The download runs in the background and can take a while; until it completes, the simulator will keep reporting `assetsUnavailable`.

You can leave the panel open and re-test the app once it shows the models as ready.

## Enable Apple Intelligence in the iOS Simulator

After the host download is done:

1. Boot an **Apple Silicon-compatible** simulator running iOS 26.x (e.g. *iPhone 17 Pro*). Older devices in the picker that don't support Apple Intelligence on real hardware will also fail in the simulator.
2. In the simulator, open **Settings → Apple Intelligence & Siri**.
3. Toggle **Apple Intelligence** on. The simulator may briefly indicate "Preparing" — this is metadata syncing, not a re-download (the assets live on the host).
4. Cold-start `FoundationForms` (delete and reinstall, or stop and re-run from Xcode) so the session is rebuilt against the now-available model.

## Verifying it works

1. Run the app, tap **Chat**.
2. Send a short message like `"Say hello in one sentence."`.
3. You should see tokens stream into the assistant bubble within a second or two.

If you still get `assetsUnavailable`, check (in this order):

- The host's **Apple Intelligence & Siri** panel says the models are ready (no progress bar).
- You're on an **Apple Silicon** Mac. Intel Macs cannot run Foundation Models in the simulator.
- The simulator destination is iOS 26.x. iOS 25.x simulators don't have the framework.
- The console log includes `com.apple.modelcatalog` — that confirms it's still an asset issue, not a code path.

## Fallback: use a real device

If the host Mac doesn't support Apple Intelligence (Intel, region, etc.), the most reliable path is a physical iPhone with Apple Intelligence enabled and the foundation models downloaded (Settings → Apple Intelligence & Siri). The app's deployment target is iOS 26.2, so any iOS 26.x device that supports Apple Intelligence will work.

## Known simulator warnings to ignore

These show up in Xcode against `FoundationModels` code paths in the iOS Simulator and are **false positives**. They do not appear on a real device and do not block generation.

### "Running as root is not supported."

Xcode pins this runtime issue to the line that touches `SystemLanguageModel.default.availability` (in `ChatViewModel.swift`). The simulator's app process is not actually running as root — `launchd_sim`, `Simulator.app`, `CoreSimulatorService`, and the iOS app itself are owned by your normal user. The only root process is `simdiskimaged`, which is CoreSimulator's disk-image mounter and is unrelated to the app.

The framework does an identity check that misfires under simulator sandboxing (likely because Foundation Models assets are reached through to the host Mac's catalog rather than living inside the iOS image), and Apple's defensive log path uses this string. As long as the chat actually returns streamed tokens, ignore the warning.

To verify your environment is clean (none of these should be `root`):

```sh
ps -axo user,pid,command | grep -E '/Xcode\.app|Simulator|CoreSimulator|launchd_sim' | grep -v grep
```

If you want to silence the inline annotation, right-click it in Xcode's Issue Navigator → **Hide Issue**, but leaving it on is fine — it doesn't repeat per turn.

### "Attempted to update accumulator from source type: 0, after completion has already been called for token: [...]"

Logged once or twice per generation in the simulator. Internal Foundation Models bookkeeping that doesn't affect your output. Safe to ignore.

## What this project does *not* require

- **No `.entitlements` capability.** There is no "Apple Intelligence" entitlement to enable in Xcode for `FoundationModels`. Gating happens entirely at runtime via `SystemLanguageModel.default.availability`.
- **No Info.plist privacy keys** are required for the basic chat usage in this app.
