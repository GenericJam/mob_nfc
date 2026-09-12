# Changelog

All notable changes to **mob_nfc** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

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
