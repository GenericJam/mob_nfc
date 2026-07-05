defmodule MobNfc.Ndef do
  @moduledoc """
  Parse raw NDEF message bytes into records, and decode the common Well-Known
  record types (Text, URI).

  `{:nfc, :ndef, %{ndef: bytes}}` delivers the raw NDEF message; run it through
  `parse/1`. Keeping the parser in Elixir (rather than the native layer) means
  one tested implementation shared across iOS and Android.

  A record is `%{tnf: 0..7, type: binary, id: binary, payload: binary}` — the
  raw NDEF fields. `tnf` (Type Name Format): 0 empty, 1 Well-Known (Text/URI),
  2 MIME, 3 absolute URI, 4 external, 5 unknown, 6 unchanged.
  """
  import Bitwise

  @type ndef_record :: %{tnf: 0..7, type: binary(), id: binary(), payload: binary()}

  # NFC Forum URI record prefix abbreviation table (URI RTD).
  @uri_prefixes {
    "",
    "http://www.",
    "https://www.",
    "http://",
    "https://",
    "tel:",
    "mailto:",
    "ftp://anonymous:anonymous@",
    "ftp://ftp.",
    "ftps://",
    "sftp://",
    "smb://",
    "nfs://",
    "ftp://",
    "dav://",
    "news:",
    "telnet://",
    "imap:",
    "rtsp://",
    "urn:",
    "pop:",
    "sip:",
    "sips:",
    "tftp:",
    "btspp://",
    "btl2cap://",
    "btgoep://",
    "tcpobex://",
    "irdaobex://",
    "file://",
    "urn:epc:id:",
    "urn:epc:tag:",
    "urn:epc:pat:",
    "urn:epc:raw:",
    "urn:epc:",
    "urn:nfc:"
  }

  @doc """
  Parse an NDEF message into its records. Returns `[]` on empty/malformed input
  (partial records already parsed are kept).
  """
  @spec parse(binary()) :: [ndef_record()]
  def parse(bytes) when is_binary(bytes), do: parse(bytes, [])
  def parse(_), do: []

  defp parse(<<>>, acc), do: Enum.reverse(acc)

  defp parse(<<flags::8, type_len::8, rest::binary>>, acc) do
    tnf = flags &&& 0x07
    sr = (flags &&& 0x10) != 0
    il = (flags &&& 0x08) != 0

    with {payload_len, rest} <- take_len(sr, rest),
         {id_len, rest} <- take_id_len(il, rest),
         <<type::binary-size(^type_len), rest::binary>> <- rest,
         <<id::binary-size(^id_len), rest::binary>> <- rest,
         <<payload::binary-size(^payload_len), rest::binary>> <- rest do
      parse(rest, [%{tnf: tnf, type: type, id: id, payload: payload} | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  defp parse(_, acc), do: Enum.reverse(acc)

  # Payload length: 1 byte (Short Record) or 4 bytes big-endian.
  defp take_len(true, <<len::8, rest::binary>>), do: {len, rest}
  defp take_len(false, <<len::32, rest::binary>>), do: {len, rest}
  defp take_len(_, _), do: :error

  defp take_id_len(true, <<len::8, rest::binary>>), do: {len, rest}
  defp take_id_len(false, rest), do: {0, rest}
  defp take_id_len(_, _), do: :error

  @doc """
  Decode a Well-Known **Text** record (`tnf: 1`, `type: "T"`) into
  `{:ok, %{text: binary, lang: binary}}`, or `:error` for any other record.
  """
  @spec decode_text(ndef_record()) :: {:ok, %{text: binary(), lang: binary()}} | :error
  def decode_text(%{tnf: 1, type: "T", payload: <<status::8, body::binary>>}) do
    lang_len = status &&& 0x3F

    case body do
      <<lang::binary-size(^lang_len), text::binary>> -> {:ok, %{text: text, lang: lang}}
      _ -> :error
    end
  end

  def decode_text(_), do: :error

  @doc """
  Decode a Well-Known **URI** record (`tnf: 1`, `type: "U"`) into
  `{:ok, uri_binary}` with the abbreviation prefix expanded, or `:error`.
  """
  @spec decode_uri(ndef_record()) :: {:ok, binary()} | :error
  def decode_uri(%{tnf: 1, type: "U", payload: <<code::8, rest::binary>>}) do
    prefix = if code < tuple_size(@uri_prefixes), do: elem(@uri_prefixes, code), else: ""
    {:ok, prefix <> rest}
  end

  def decode_uri(_), do: :error
end
