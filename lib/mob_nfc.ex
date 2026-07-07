defmodule MobNfc do
  @moduledoc """
  NFC — read NDEF messages from nearby tags.

  iOS uses `CoreNFC` (`NFCNDEFReaderSession`, iPhone 7+); Android uses
  `NfcAdapter` reader mode (`enableReaderMode`). Reads NDEF messages
  (`start_reading/2`) and writes them (`write_ndef/3`). Card emulation (HCE) is
  a planned Android-only follow-up.

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
      {:nfc, :written, %{bytes: integer}}               # write_ndef/3 succeeded
      {:nfc, :session_ended, reason}                    # :done | :user_cancel | :error | ...
      {:nfc, :error, reason}                            # :disabled | :unavailable | :read_failed | :read_only | :too_small | :not_ndef | ...

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

  @doc """
  Write an NDEF message to the next tag tapped; result flows to the caller.

  `content` is either the raw NDEF message bytes (a `binary`) or a record / list
  of records to encode via `MobNfc.Ndef.encode/1`:

      MobNfc.write_ndef(socket, MobNfc.Ndef.uri_record("https://mob.dev"))
      MobNfc.write_ndef(socket, [MobNfc.Ndef.text_record("hi"), uri_rec])

  This opens the same reader UI as `start_reading/2` (iOS system sheet; Android
  foreground reader mode) but, on tag detection, writes instead of reads. The
  tag must be NDEF-formatted and writable and have enough capacity. Results:

      {:nfc, :written, %{bytes: integer}}     # wrote N bytes successfully
      {:nfc, :error, :read_only}              # tag is locked / not writable
      {:nfc, :error, :too_small}              # message exceeds tag capacity
      {:nfc, :error, :not_ndef}               # tag isn't NDEF-formatted
      {:nfc, :error, :write_failed}           # I/O error mid-write

  ## Options

    * `:alert` — iOS reader-sheet prompt string. Ignored on Android.
  """
  @spec write_ndef(Mob.Socket.t(), binary() | map() | [map()], keyword()) :: Mob.Socket.t()
  def write_ndef(socket, content, opts \\ []) do
    if Platform.unsupported?(Platform.current()) do
      send(self(), {:nfc, :error, :unsupported})
    else
      bytes = if is_binary(content), do: content, else: MobNfc.Ndef.encode(content)
      alert = Keyword.get(opts, :alert, "Hold your phone near a writable NFC tag")
      json = Jason.encode!(%{alert: alert, ndef: Base.encode64(bytes)})
      :mob_nfc_nif.nfc_start_writing(json)
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

  @doc """
  Emulate an NDEF tag (Host Card Emulation) — make this phone read like an NFC
  tag serving `content` to any nearby reader. **Android only.**

  `content` is raw NDEF bytes or record(s) (encoded via `MobNfc.Ndef.encode/1`),
  the same as `write_ndef/3`. The phone advertises an NFC Forum Type-4 tag over
  the NDEF application AID `D2760000850101`; a reader (another phone, an NFC
  reader, an iPhone running `start_reading/2`) sees a normal read-only NDEF tag.

      MobNfc.emulate_ndef(socket, MobNfc.Ndef.uri_record("https://mob.dev"))

  iOS has no third-party HCE API (the Secure Element is reserved), so this sends
  `{:nfc, :error, :unsupported}` there. Events:

      {:nfc, :emulation_started}
      {:nfc, :hce_read}                  # a reader read the emulated tag
      {:nfc, :hce_written, %{ndef: bin}} # a reader wrote to it (`:writable` only)
      {:nfc, :emulation_stopped}

  ## Options

    * `:writable` — when `true`, advertise the emulated tag as writable so a
      reader (e.g. another phone's `write_ndef/3`) can write into it; the new
      message arrives as `{:nfc, :hce_written, %{ndef: bytes}}` and becomes what
      the tag subsequently serves. Defaults to `false` (read-only tag).

  Requires the `HostApduService` + `res/xml` + AndroidManifest `<service>` the
  plugin `host_requirements` describe (mob_dev can't contribute those yet).
  """
  @spec emulate_ndef(Mob.Socket.t(), binary() | map() | [map()], keyword()) :: Mob.Socket.t()
  def emulate_ndef(socket, content, opts \\ []) do
    case Platform.current() do
      :host ->
        send(self(), {:nfc, :error, :unsupported})

      :ios ->
        send(self(), {:nfc, :error, :unsupported})

      _ ->
        bytes = if is_binary(content), do: content, else: MobNfc.Ndef.encode(content)
        writable = Keyword.get(opts, :writable, false) == true

        :mob_nfc_nif.nfc_emulate_ndef(
          Jason.encode!(%{ndef: Base.encode64(bytes), writable: writable})
        )
    end

    socket
  end

  @doc "Stop tag emulation started by `emulate_ndef/3`. Android only; no-op elsewhere."
  @spec stop_emulation(Mob.Socket.t()) :: Mob.Socket.t()
  def stop_emulation(socket) do
    case Platform.current() do
      p when p in [:host, :ios] -> :ok
      _ -> :mob_nfc_nif.nfc_stop_emulation()
    end

    socket
  end
end
