# iOS review and build

Upstream: `wlx219/huangguo-vip-app`, commit
`fe6bdbcfbf697fc26fd8bd4a7c38fe8e4ba74f3b`.

## Toolchain

- Flutter 3.24.5 / Dart 3.5.4, matching the upstream successful iOS build.
- iOS compilation runs on the `macos-14` GitHub Actions runner.
- The workflow is manually triggered and runs static analysis and regression
  tests before compiling. It has read-only repository permissions.

## Local checks

```text
flutter pub get
flutter analyze
flutter test
```

Tests use synthetic API responses and fake video controllers. They do not
download or play remote media. Native video playback still needs verification
on the intended device.

Local verification on 2026-11-20: static analysis reported no issues, all 47
tests passed, and all seven iOS plist/storyboard/scheme XML files parsed.

## Changes

- Align the application's dark theme and color scheme.
- Handle failed requests, retries, pagination, filter cancellation and delayed
  callbacks after leaving a page.
- Load episode metadata and short-lived playback credentials using separate
  API requests. Refresh credentials on retry; do not persist playback URLs.
- Handle video initialization failures, restore progress before starting, and
  release controllers when leaving the player.
- Restore iOS's default App Transport Security policy; HTTPS is required.
- Exclude generated machine-specific plugin files from version control.

## Build and installation

Run the `Build iOS IPA` workflow for the reviewed branch. Its artifact,
`huangguo-vip-ipa`, contains `huangguo-vip-unsigned.ipa`.

This is an **unsigned** device build, not an App Store or TestFlight release.
It must be signed with the user's Apple account or an appropriate development
certificate and provisioning profile before iPhone installation. Keep Apple
credentials and signing material out of this repository and its Actions logs.

On Windows, Sideloadly can sign and install the IPA with a connected iPhone.
The user must complete Apple authentication locally, and confirm any required
trust or Developer Mode prompts on the phone. Free-account signing generally
expires after seven days.
