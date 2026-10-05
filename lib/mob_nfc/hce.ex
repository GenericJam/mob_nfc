defmodule MobNfc.Hce do
  @moduledoc """
  Pure NFC Forum **Type-4 Tag (T4T) APDU responder** — the tested reference
  implementation of the Host Card Emulation state machine.

  The Android `MobNfcApduService`
  (`priv/native/android/MobNfcBridge.kt`) is a faithful Kotlin mirror of this:
  identical Capability Container bytes, identical SELECT / READ BINARY /
  UPDATE BINARY handling, identical write-completion detection. Because an
  Android `HostApduService` must answer a reader even when the BEAM isn't
  running, the Kotlin can't delegate here at runtime — so this module exists to
  pin the protocol logic in host-runnable tests, and the Kotlin is reviewed
  against it.

  `handle_apdu/2` is pure:

      {response_bytes, new_state, event} = MobNfc.Hce.handle_apdu(apdu, state)

  where `event` is `nil`, `:read` (a reader finished reading the NDEF file), or
  `{:written, ndef_bytes}` (a reader wrote a new message into a writable tag).

  A T4T read is: SELECT NDEF app → SELECT CC → READ CC → SELECT NDEF file →
  READ BINARY. A write (writable tag only) additionally issues UPDATE BINARY
  commands: NLEN=0, the message at offset 2, then the real NLEN at offset 0.
  """

  @sw_ok <<0x90, 0x00>>
  @sw_file_not_found <<0x6A, 0x82>>
  @sw_ins_not_supported <<0x6D, 0x00>>
  @sw_error <<0x6F, 0x00>>

  # Max NDEF file size advertised in the CC (0x0400 = 1024, incl. 2-byte NLEN).
  @capacity 1024
  # Largest NDEF message that fits that file (capacity minus the NLEN prefix).
  @max_message_size @capacity - 2

  @type selected :: :none | :cc | :ndef
  # `ndef: nil` = emulation stopped (see `stop/1`): every APDU is refused.
  @type state :: %{
          selected: selected(),
          ndef: binary() | nil,
          writable: boolean(),
          write_buf: binary() | nil
        }
  @type event :: nil | :read | {:written, binary()}

  @doc """
  Largest NDEF message (bytes) an emulated tag can serve: the CC advertises a
  #{@capacity}-byte NDEF file, of which 2 bytes are the NLEN length prefix.
  """
  @spec max_message_size() :: pos_integer()
  def max_message_size, do: @max_message_size

  @doc """
  `:ok` when `ndef` fits the advertised NDEF file (≤ #{@max_message_size}
  bytes), else `{:error, :too_large}`.
  """
  @spec check_size(binary()) :: :ok | {:error, :too_large}
  def check_size(ndef) when byte_size(ndef) <= @max_message_size, do: :ok
  def check_size(ndef) when is_binary(ndef), do: {:error, :too_large}

  @doc """
  Initial responder state serving `ndef`, optionally writable.

  Raises `ArgumentError` when `ndef` exceeds `max_message_size/0` — the CC
  would otherwise advertise a file smaller than the NLEN it serves.
  """
  @spec new(binary(), boolean()) :: state()
  def new(ndef, writable \\ false) when is_binary(ndef) and is_boolean(writable) do
    if check_size(ndef) != :ok do
      raise ArgumentError,
            "NDEF message is #{byte_size(ndef)} bytes; an emulated tag serves at most " <>
              "#{@max_message_size}"
    end

    %{selected: :none, ndef: ndef, writable: writable, write_buf: nil}
  end

  @doc """
  Stop emulating: drop the served message and any half-written buffer. A
  stopped responder refuses every APDU with `6A82` (the Android service does
  the same once emulation is stopped or the app is backgrounded).
  """
  @spec stop(state()) :: state()
  def stop(state), do: %{state | selected: :none, ndef: nil, write_buf: nil}

  @doc """
  Handle one command APDU. Returns `{response_bytes, new_state, event}`.

  Unknown instructions get `6D00`; malformed/oversized get `6F00`; a SELECT of
  an unknown file id gets `6A82`; a stopped responder (`stop/1`) answers `6A82`
  to everything.
  """
  @spec handle_apdu(binary(), state()) :: {binary(), state(), event()}
  def handle_apdu(apdu, state)

  # Not emulating: refuse everything, so a reader can't select the NDEF app.
  def handle_apdu(_apdu, %{ndef: nil} = state), do: {@sw_file_not_found, state, nil}

  # SELECT by name (AID) — the NDEF Tag Application (00 A4 04 00 <len> <aid> …).
  def handle_apdu(<<0x00, 0xA4, 0x04, _rest::binary>>, state) do
    {@sw_ok, %{state | selected: :none}, nil}
  end

  # SELECT by file id (00 A4 00 0C 02 <fid_hi> <fid_lo>).
  def handle_apdu(<<0x00, 0xA4, 0x00, 0x0C, 0x02, fid::16>>, state) do
    case fid do
      0xE103 -> {@sw_ok, %{state | selected: :cc}, nil}
      0xE104 -> {@sw_ok, %{state | selected: :ndef}, nil}
      _ -> {@sw_file_not_found, %{state | selected: :none}, nil}
    end
  end

  # Any other SELECT shape is malformed for our applet.
  def handle_apdu(<<0x00, 0xA4, _rest::binary>>, state), do: {@sw_error, state, nil}

  # READ BINARY (00 B0 <off_hi> <off_lo> [<le>]).
  def handle_apdu(<<0x00, 0xB0, offset::16, le::8>>, state), do: read_binary(offset, le, state)
  def handle_apdu(<<0x00, 0xB0, offset::16>>, state), do: read_binary(offset, 0, state)

  # UPDATE BINARY (00 D6 <off_hi> <off_lo> <lc> <data…>).
  def handle_apdu(<<0x00, 0xD6, offset::16, lc::8, data::binary>>, state)
      when byte_size(data) == lc do
    update_binary(offset, data, state)
  end

  # A D6 that isn't well-formed: reject as read-only first (matches the write
  # gate), else malformed.
  def handle_apdu(<<0x00, 0xD6, _rest::binary>>, state) do
    if state.writable and state.selected == :ndef,
      do: {@sw_error, state, nil},
      else: {@sw_file_not_found, state, nil}
  end

  def handle_apdu(_apdu, state), do: {@sw_ins_not_supported, state, nil}

  # ── files ──────────────────────────────────────────────────────────────────

  @doc """
  The 15-byte Capability Container. Write-access byte is `00` (writable) when
  `writable`, else `FF` (read-only); the NDEF File Control TLV points at file
  `E104` with max size #{@capacity}.
  """
  @spec cc(boolean()) :: binary()
  def cc(writable) do
    write = if writable, do: 0x00, else: 0xFF
    <<0x00, 0x0F, 0x20, 0x00, 0xFB, 0x00, 0xFF, 0x04, 0x06, 0xE1, 0x04, 0x04, 0x00, 0x00, write>>
  end

  @doc "The NDEF file image: 2-byte NLEN (message length) followed by the message."
  @spec ndef_file(binary()) :: binary()
  def ndef_file(msg), do: <<byte_size(msg)::16>> <> msg

  # ── command handlers ─────────────────────────────────────────────────────

  defp read_binary(offset, le, state) do
    case file_for(state) do
      :none ->
        {@sw_file_not_found, state, nil}

      file when offset > byte_size(file) ->
        {@sw_error, state, nil}

      file ->
        ending = min(offset + le, byte_size(file))
        slice = binary_part(file, offset, ending - offset)
        event = if state.selected == :ndef and ending >= byte_size(file), do: :read, else: nil
        {slice <> @sw_ok, state, event}
    end
  end

  defp file_for(%{selected: :cc, writable: w}), do: cc(w)
  defp file_for(%{selected: :ndef, ndef: n}), do: ndef_file(n)
  defp file_for(%{selected: :none}), do: :none

  defp update_binary(offset, data, state) do
    lc = byte_size(data)

    cond do
      not state.writable or state.selected != :ndef ->
        {@sw_file_not_found, state, nil}

      offset + lc > @capacity ->
        {@sw_error, state, nil}

      true ->
        buf = splice(state.write_buf || :binary.copy(<<0>>, @capacity), offset, data)
        <<nlen::16, _::binary>> = buf

        # A non-zero NLEN means the reader has finalised the write.
        if nlen >= 1 and nlen <= @max_message_size do
          {@sw_ok, %{state | write_buf: nil}, {:written, binary_part(buf, 2, nlen)}}
        else
          {@sw_ok, %{state | write_buf: buf}, nil}
        end
    end
  end

  # Overwrite `buf[offset, offset+byte_size(data))` with `data`.
  defp splice(buf, offset, data) do
    lc = byte_size(data)
    tail_at = offset + lc
    binary_part(buf, 0, offset) <> data <> binary_part(buf, tail_at, byte_size(buf) - tail_at)
  end
end
