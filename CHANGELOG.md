# Changelog

All notable changes to **mob_nfc** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed
- **Android HCE now claims routing while the app is in the foreground**
  (MOB-300). `emulate_ndef/3` calls
  `CardEmulation.setPreferredService` for `io.mob.nfc.MobNfcApduService`
  while the host activity is resumed, and `unsetPreferredService` on
  `stop_emulation/1` and when the activity pauses (re-claimed on resume if
  still emulating). Previously any other installed app registering the NDEF
  AID `D2760000850101` competed for routing, so a reader tap could land in
  Android's AID-conflict chooser. Skipped on devices without NFC/HCE; the
  claim/release results are logged under the `MobNfc` logcat tag.

## [0.1.1] - 2026-09-30

### Fixed
- **`MobNfc.start_reading/2`, `write_ndef/3`, `emulate_ndef/3` no longer
  crash with `UndefinedFunctionError (Jason.encode!/1)` in a consumer that
  doesn't pull Jason transitively** (MOB-80). The three transport helpers
  called `Jason.encode!` while `mix.exs` declared no `:jason` dep — Jason
  was only present via dev/test tooling (credo, mob_dev). A regular Mob
  app on `{:mob, "~> 0.7"} + {:mob_nfc, "~> 0.1"}` hit the exception on
  the first call. Switched all three sites to the built-in `JSON` stdlib
  (Elixir 1.18+, which mix.exs already targets); no runtime dep added.
  A source-scanning lint test guards against regression.

### Changed
- **Android HCE is now turnkey** (MOB-39). The HCE `<service>`
  (`io.mob.nfc.MobNfcApduService`) is contributed via
  `android.manifest_application_snippets`, and the plugin ships its own
  `res/xml/mob_nfc_hce_apduservice.xml` and `res/values/mob_nfc_strings.xml`
  via `android.res_files` — no manual manifest/res edits. The service
  description is now `@string/mob_nfc_hce_description` instead of
  `@string/app_name`. The manual HCE `host_requirement` is removed.
  Requires mob_dev ≥ 0.6.19; older mob_dev silently ignores these keys.
  **Upgrading from 0.1.0 with HCE set up by hand:** delete the
  `<service android:name="io.mob.nfc.MobNfcApduService">` block from
  `android/app/src/main/AndroidManifest.xml` and the hand-created
  `android/app/src/main/res/xml/mob_nfc_apduservice.xml`. mob_dev skips a
  snippet whose `android:name` is already in the manifest, so if you keep
  the hand-added `<service>` it keeps pointing at your old
  `@xml/mob_nfc_apduservice` (still works, but the plugin's file is unused).
  The plugin file was renamed so it never collides with the host-owned one.
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.

## [0.1.0] - 2026-07-07

### Added
- Initial release: on-device **NFC** for Mob apps. (MOB-16)
  - **Read** NDEF messages — `MobNfc.start_reading/2` / `stop_reading/1` open a
    reader session; NDEF and tag events arrive as `{:nfc, ...}` messages.
    `MobNfc.available?/0` reports radio presence + enabled state.
  - **Raw tag UIDs** — `start_reading/2` with `mode: :tag` reads a tag's UID/tech
    without NDEF (iOS `NFCTagReaderSession`).
  - **Write** NDEF — `MobNfc.write_ndef/3` writes an NDEF message to a tag.
  - **Card emulation (HCE)** — `MobNfc.emulate_ndef/3` / `stop_emulation/1`
    emulate an NDEF tag (read-only or `:writable`) via Android `HostApduService`.
    **Android only** (iOS has no third-party HCE; it replies `:unsupported`).
  - iOS `CoreNFC`; Android `NfcAdapter` reader mode + HCE. NDEF parse/encode and
    Text/URI helpers in `MobNfc.Ndef`.
