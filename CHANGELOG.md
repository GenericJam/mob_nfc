# Changelog

All notable changes to **mob_nfc** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - unreleased

### Added
- Initial release: **NDEF tag reading**. `MobNfc.start_reading/2` /
  `stop_reading/1` open a reader session; NDEF records and tag events arrive as
  `{:nfc, ...}` messages. `MobNfc.available?/0` reports radio presence + enabled
  state. iOS `CoreNFC` (`NFCNDEFReaderSession`); Android `NfcAdapter` reader
  mode. (MOB-16)
