# mob_nfc

NFC for [Mob](https://github.com/GenericJam/mob) apps — read NDEF messages from
nearby tags. iOS `CoreNFC` (iPhone 7+) / Android `NfcAdapter` reader mode.

> Status: NDEF **read** (this release). Tag **write** and card emulation (HCE)
> are planned follow-ups.

## Install

```elixir
# mix.exs
{:mob_nfc, "~> 0.1"}
```

```elixir
# mob.exs — plugins are opt-in (a bare deps.get does nothing)
config :mob, :plugins, [:mob_nfc]
```

### Host setup

- **Android** — the plugin adds `android.permission.NFC` (install-time). Add a
  `<uses-feature android:name="android.hardware.nfc" android:required="false"/>`
  to your `AndroidManifest.xml` so NFC-less devices still install.
- **iOS** — the plugin adds the `NFCReaderUsageDescription` Info.plist string,
  but you must add the entitlement to `ios/<app>.entitlements` yourself (the
  build prints this) and provision an NFC-capable profile (`mix mob.provision`):

  ```xml
  <key>com.apple.developer.nfc.readersession.formats</key>
  <array><string>NDEF</string><string>TAG</string></array>
  ```

## Use

```elixir
def handle_event("scan", _params, socket) do
  {:noreply, MobNfc.start_reading(socket, alert: "Hold near a tag")}
end

def handle_info({:nfc, :ndef, %{records: records}}, socket) do
  {:noreply, assign(socket, :records, records)}
end

def handle_info({:nfc, :session_ended, _reason}, socket), do: {:noreply, socket}
```

`MobNfc.available?/0` reports whether the radio is present and switched on.
Reading is a no-op on the simulator/emulator (no radio).

See the `MobNfc` moduledoc for the full event list and NDEF record shape.
