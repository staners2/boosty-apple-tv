# Development and verification

Use full Xcode with tvOS support and XcodeGen 2.46+. Set `DEVELOPER_DIR` if Xcode
is not at `/Applications/Xcode.app/Contents/Developer`. The minimum deployment
target is tvOS 17.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Sources/BoostyCore` | HTTPS endpoints, broker contract, session and device-proof headers. |
| `App` | SwiftUI, AppModel, Keychain, AVKit, progress and frame cache. |
| `Tests` | API, state, cancellation, localization, timeline and playback regressions. |
| `UITests` | Native tvOS interactions through XCTest and Siri Remote commands. |
| `UITests/Fixtures` | Local HTTPS broker and separate fixture-only app host. |
| `project.yml`, `project-fixtures.yml` | XcodeGen project and fixture targets. |
| `scripts/generate-assets.swift` | Generated app icon and Top Shelf assets. |

Run `./scripts/generate.sh` to regenerate projects and assets. Generated projects,
assets, build products and test certificates are ignored by Git.

## Unit tests and builds

```sh
./scripts/test.sh
./scripts/build.sh simulator
./scripts/build.sh device
```

`device` disables signing and only checks SDK compatibility. Device installation
and TestFlight need your own signing setup; see the [README](../README.md#install-on-apple-tv).
CI scans Git history with Gitleaks, runs unit tests and builds the unsigned
simulator app, without signing secrets or a real Boosty account. It does not run
the UI suite. Personal names and email addresses require a separate review of
Git authorship; a clean secret scan is not a privacy guarantee.

## Simulator UI scenarios

Install the extra tools and boot an available Apple TV simulator in Xcode:

```sh
brew install ffmpeg
UI_FIXTURE_HOST=1 ./scripts/test-ui.sh CODE_SIGNING_ALLOWED=NO -parallel-testing-enabled NO
```

If needed, set `SIMULATOR_UDID` to an identifier from
`xcrun simctl list devices available`. Results and screenshots are saved in
`build/ParityTests-*.xcresult`.

`UI_FIXTURE_HOST=1` selects **BoostyParity**, a separate app using production
views and AppModel. Its URLProtocol trusts only the generated one-day localhost
CA, with normal hostname and chain validation. It uses ephemeral sessions and
fictional posts. AVPlayer uses Apple's public HLS sample, so playback tests need
network access to Apple's sample CDN. Test login and trust overrides are not in
the production app. The Mac trust store is not modified.

Without this flag, the script tests the main app and attempts certificate import
into the simulator with a 30-second timeout. On some runtimes this import stalls;
use the isolated fixture host instead of disabling TLS.

## Recorded baseline

On 17 October 2026, Xcode 27.1 with tvOS Simulator 27 passed **105 unit tests**
(26 Core, 79 AppState) and **11 UI tests**, with no failures or skips. UI coverage
includes setup, HTTP rejection, phone links/files, pagination, returning to the
selected card, long post scrolling, chapters, previews, paused quality changes,
seek cancellation, localization, root Back and profile disconnection.

A signed 0.1.2 (3) build was installed and launched on Apple TV 4K (3rd generation).
That does not prove production Boosty login, CDN playback or physical remote
gestures. Those checks and TestFlight remain separate acceptance steps.

Known diagnostics in this baseline were an AVAudioSession synchronous-activation
warning and failed optional Xcode simulator-diagnostics collection with the global
developer directory set to CommandLineTools. They did not fail the tests; scripts
explicitly select full Xcode. Do not change global settings to hide this warning.

The README screenshots were exported from this UI run; the player image shows
Apple's public sample media, not Boosty content. See the
[feature matrix](samsung-parity.md) for implementation and test boundaries.

## Publication verification

The privacy-cleaned source passed 105 unit tests and an unsigned simulator build.
The default app identity and generated asset author metadata are neutral. Gitleaks
found no secrets in the publication snapshot; screenshot text/EXIF metadata was
removed without changing decoded images. Author and committer use a GitHub
noreply address.

The latest full UI run passed **10 of 11** scenarios. The player scenario timed
out waiting for the external Apple HLS sample to become ready or start playing;
an isolated rerun also failed. The manifest returned HTTP 200 from the Mac, which
does not prove media segment delivery or simulator playback. The cause remains
unresolved. The earlier 11/11 baseline above must not be treated as a passing
result for this publication run. No test was skipped or removed to hide this.
