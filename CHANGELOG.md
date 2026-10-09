# Changelog

All notable changes to **mob_nfc** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **On-device self-test** (MOB-418). `MobNfc.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  makes one read-only `nfc_available/0` call: `true` passes, `false` (the
  native side answered, but there is no radio, as on every simulator and
  emulator) is `{:skip, :needs_hardware}`, `:disabled` is a skip naming the
  switched-off radio, and an error answer or the host stub's
  `nif_not_loaded` fails. Run it with `mix mob.selftest` from a host app
  (mob_dev 0.7.17). `mob_version` in the manifest is now `~> 0.9`.

### Changed

- **Requires mob 0.9.15 or later** (was `~> 0.7`): hosts on mob 0.7 or 0.8
  must upgrade before taking this release.
- **Android: `nfc_available/0` no longer answers `false` without asking the
  radio.** `false` now means only "no NFC hardware"; the other answers are:
  - `:disabled`: the radio is present but switched off;
  - `{:error, :bridge_not_registered}`: `MobNfcBridge.register()` never ran
    or the method-id lookup failed;
  - `{:error, :no_activity}`: the bootstrap hasn't handed the bridge an
    Activity;
  - `{:error, :no_jni_env}`: no JNIEnv could be attached;
  - `{:error, :bridge_exception}`: the Kotlin side threw (a pending Java
    exception is now detected and cleared);
  - `{:error, :unknown_state}`: the bridge returned a code the NIF doesn't
    know.

  The Kotlin bridge method is now `nfc_state(): Int` (was
  `nfc_available(): Boolean`). `MobNfc.available?/0` is unchanged (still
  `false` for all of these). Method-id lookups in `nativeRegister` now clear
  a pending `NoSuchMethodError` so one missing method can't poison the rest.

---

## [0.1.4] - 2026-10-05

Fixes from the Operator v1 release review (MOB-395).

### Changed (behaviour)
- **HCE no longer serves while the phone is locked.** The contributed
  `res/xml/mob_nfc_hce_apduservice.xml` now declares
  `android:requireDeviceUnlock="true"` (was `"false"`).
- **HCE emulation is foreground-only and is now stopped on background.**
  When the host activity pauses (backgrounded, screen off, a permission
  prompt / dialog-style activity on top, an activity-recreating config change) the emulated payload is
  dropped, the preferred-service claim released, `MobNfcApduService` refuses
  every APDU (`6A82`), and the owner receives `{:nfc, :emulation_stopped}`.
  Previously only the routing preference was released and the payload was
  retained and re-armed on resume. Apps that want emulation back must call
  `MobNfc.emulate_ndef/3` again, e.g. on `{:mob_device, :did_become_active}`.
- An `emulate_ndef/3` call that passes the up-front checks (size, payload, an
  attached activity) but then fails ends any emulation already running, and a
  successful one from another process replaces it; the previous owner gets
  `{:nfc, :emulation_stopped}` in both cases. Reader mode is dropped only once
  emulation is actually live, so a failed emulate no longer kills a reader
  session.

### Fixed
- **`emulate_ndef/3` no longer claims success on hardware that can't
  emulate.** `{:nfc, :emulation_started}` is sent only when the device has
  `FEATURE_NFC_HOST_CARD_EMULATION`, the NFC adapter exists and is enabled,
  the activity is resumed, and `CardEmulation.setPreferredService` succeeded.
  Otherwise one error arrives instead: `{:nfc, :error, :unavailable}`
  (no NFC / no HCE / app not in the foreground / routing refused),
  `{:nfc, :error, :disabled}` (NFC switched off), matching `start_reading/2`,
  or `{:nfc, :error, :no_activity}` (no host activity attached yet).
- **NDEF messages larger than the emulated file are rejected.** The emulated
  tag advertises a 1024-byte NDEF file including the 2-byte NLEN, so
  `emulate_ndef/3` now rejects messages over 1022 bytes with
  `{:nfc, :error, :too_large}` (checked in Elixir before the NIF, and again in
  the Android bridge). New `MobNfc.Hce.max_message_size/0`,
  `MobNfc.Hce.check_size/1`, and `MobNfc.Hce.stop/1` (the pure reference for the
  stopped-service behaviour); `MobNfc.Hce.new/2` raises on an oversized message.

## [0.1.3] - 2026-10-04

### Changed
- **Signed with the shared mob first-party plugin key** (MOB-390).
  `priv/mob_plugin.pub` is now the key shared by the other first-party
  `mob_*` plugins (fingerprint
  `ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=`), the same key as the other
  first-party plugins. Trust is still recorded per plugin name: map
  `mob_nfc: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="` in
  `config :mob, :trusted_plugins` or run `mix mob.plugin.trust mob_nfc`. Hosts that
  recorded the old per-repo fingerprint for 0.1.2 will get a key-rotation
  error; re-run `mix mob.plugin.trust mob_nfc` or switch the entry to the
  shared fingerprint.

## [0.1.2] - 2026-09-30

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
