# Changelog

All notable changes to **mob_nfc** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

- **`Jason` declared as a runtime dependency** (MOB-80). `MobNfc` uses
  `Jason.encode!` on three write paths (write_ndef, hce_start, tag_emulate)
  but the plugin's `mix.exs` never declared `:jason`. It only worked in
  practice because most host apps declare `:jason` transitively; a minimal
  host would fail at first invocation with `UndefinedFunctionError`.

---

## [0.1.0] - unreleased

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
