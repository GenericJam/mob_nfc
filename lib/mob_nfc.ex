defmodule MobNfc do
  @moduledoc """
  NFC — read NDEF messages from nearby tags.

  iOS uses `CoreNFC` (`NFCNDEFReaderSession`, iPhone 7+); Android uses
  `NfcAdapter` reader mode (`enableReaderMode`). Tag *writing* and card
  emulation (HCE) are planned follow-ups — this first cut is NDEF reading.

  ## API style

  Same as the rest of Mob: calls return the `socket` unchanged and results
  arrive in `handle_info/2` as `{:nfc, ...}` messages delivered to the process
  that started the session.

      def handle_event("scan", _p, socket) do
        {:noreply, MobNfc.start_reading(socket)}
      end

      def handle_info({:nfc, :ndef, %{records: records}}, socket) do
        {:noreply, assign(socket, :last_tag, records)}
      end

  ## Events (tagged `:nfc`)

      {:nfc, :session_started}
      {:nfc, :ndef, %{tag_id: binary, ndef: binary, writable: boolean, max_size: integer}}
      {:nfc, :tag, %{tag_id: binary, tech: binary}}     # a tag with no NDEF data
      {:nfc, :session_ended, reason}                    # :done | :user_cancel | :error | ...
      {:nfc, :error, reason}                            # :disabled | :unavailable | :read_failed | ...

  `ndef` is the **raw NDEF message bytes**. Turn it into records with
  `MobNfc.Ndef.parse/1` (one tested parser shared across platforms), and decode
  the common Text/URI records with `MobNfc.Ndef.decode_text/1` / `decode_uri/1`:

      def handle_info({:nfc, :ndef, %{ndef: bytes}}, socket) do
        uris =
          bytes
          |> MobNfc.Ndef.parse()
          |> Enum.flat_map(fn r ->
            case MobNfc.Ndef.decode_uri(r) do
              {:ok, uri} -> [uri]
              :error -> []
            end
          end)

        {:noreply, assign(socket, :uris, uris)}
      end

  For a non-NDEF tag, `{:nfc, :tag, %{tech: "..."}}` carries the comma-joined
  Android tech-list (`tech` is empty on iOS).

  ## Availability

  `available?/0` is true only on a device whose NFC radio is present **and**
  switched on. Reading does nothing on a simulator/emulator (no radio) and on a
  device with NFC turned off in system settings.

  ## Permissions & setup

  Android NFC is an install-time permission (no runtime dialog); the plugin adds
  it to the manifest. iOS requires the `com.apple.developer.nfc.readersession
  .formats` **entitlement** and an `NFCReaderUsageDescription` Info.plist string
  — the plist key is added by the plugin, but the entitlement must be added to
  `ios/<app>.entitlements` by hand for now (the build prints the obligation; see
  the plugin `host_requirements`).
  """

  alias MobNfc.Platform

  @doc """
  True when the device has an NFC radio that is present and enabled.

  Returns `false` on the host/simulator and on a device with NFC switched off.
  """
  @spec available?() :: boolean()
  def available? do
    case Platform.current() do
      :host -> false
      _ -> :mob_nfc_nif.nfc_available() == true
    end
  end

  @doc """
  Start an NFC reader session; NDEF/tag events flow to the calling process.

  On iOS this presents the system reader sheet with `opts[:alert]` as its
  prompt (default provided). On Android it enables foreground reader mode; there
  is no sheet. Returns `socket` unchanged. No-op returning `{:error,
  :unsupported}` semantics are surfaced as a `{:nfc, :error, :unsupported}`
  message rather than a raise, to match the async contract.

  ## Options

    * `:alert` — iOS reader-sheet prompt string. Ignored on Android.
    * `:mode` — `:ndef` (default) or `:tag`. **iOS only** — picks the CoreNFC
      session: `:ndef` (`NFCNDEFReaderSession`, reads NDEF messages) or `:tag`
      (`NFCTagReaderSession`, reads any tag's UID + type, incl. non-NDEF
      smartcards like payment cards). Android's reader mode always surfaces both
      (`{:nfc, :ndef, ...}` for NDEF, `{:nfc, :tag, ...}` otherwise) regardless
      of `:mode`.
  """
  @spec start_reading(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def start_reading(socket, opts \\ []) do
    if Platform.unsupported?(Platform.current()) do
      send(self(), {:nfc, :error, :unsupported})
    else
      alert = Keyword.get(opts, :alert, "Hold your phone near an NFC tag")
      mode = if Keyword.get(opts, :mode) == :tag, do: "tag", else: "ndef"
      :mob_nfc_nif.nfc_start_reading(Jason.encode!(%{alert: alert, mode: mode}))
    end

    socket
  end

  @doc "Stop the reader session started by the calling process."
  @spec stop_reading(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_reading(socket) do
    unless Platform.unsupported?(Platform.current()) do
      :mob_nfc_nif.nfc_stop_reading()
    end

    socket
  end
end
