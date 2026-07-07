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

  @doc """
  Encode records into a raw NDEF message binary — the inverse of `parse/1`,
  ready for `MobNfc.write_ndef/3`. Sets MB/ME on the first/last record, uses the
  Short-Record form when the payload is ≤ 255 bytes, and includes the ID field
  only when non-empty. Accepts a single record or a list.

      MobNfc.Ndef.encode([MobNfc.Ndef.uri_record("https://mob.io")])
  """
  @spec encode(ndef_record() | [ndef_record()]) :: binary()
  def encode(record) when is_map(record), do: encode([record])

  def encode(records) when is_list(records) do
    n = length(records)

    records
    |> Enum.with_index()
    |> Enum.map(fn {r, i} -> encode_record(r, i == 0, i == n - 1) end)
    |> IO.iodata_to_binary()
  end

  defp encode_record(r, first?, last?) do
    tnf = Map.get(r, :tnf, 1)
    type = Map.get(r, :type, "")
    id = Map.get(r, :id, "")
    payload = Map.get(r, :payload, "")

    sr = byte_size(payload) <= 255
    il = byte_size(id) > 0

    flags =
      bor_all([
        if(first?, do: 0x80, else: 0),
        if(last?, do: 0x40, else: 0),
        if(sr, do: 0x10, else: 0),
        if(il, do: 0x08, else: 0),
        tnf &&& 0x07
      ])

    payload_len =
      if sr, do: <<byte_size(payload)::8>>, else: <<byte_size(payload)::32>>

    id_len = if il, do: <<byte_size(id)::8>>, else: <<>>

    [<<flags::8, byte_size(type)::8>>, payload_len, id_len, type, id, payload]
  end

  defp bor_all(list), do: Enum.reduce(list, 0, &bor/2)

  @doc """
  Build a Well-Known **Text** record (UTF-8) for `encode/1` / `write_ndef/3`.

      MobNfc.Ndef.text_record("hello")            # lang "en"
      MobNfc.Ndef.text_record("bonjour", "fr")
  """
  @spec text_record(binary(), binary()) :: ndef_record()
  def text_record(text, lang \\ "en") when is_binary(text) and is_binary(lang) do
    status = byte_size(lang) &&& 0x3F
    %{tnf: 1, type: "T", id: "", payload: <<status::8, lang::binary, text::binary>>}
  end

  @doc """
  Build a Well-Known **URI** record, abbreviating a known scheme/prefix per the
  URI RTD table so the tag stores fewer bytes.

      MobNfc.Ndef.uri_record("https://mob.io")   # prefix code 0x04 + "mob.io"
  """
  @spec uri_record(binary()) :: ndef_record()
  def uri_record(uri) when is_binary(uri) do
    {code, rest} = abbreviate_uri(uri)
    %{tnf: 1, type: "U", id: "", payload: <<code::8, rest::binary>>}
  end

  defp abbreviate_uri(uri) do
    {code, prefix} =
      1..(tuple_size(@uri_prefixes) - 1)
      |> Enum.map(fn i -> {i, elem(@uri_prefixes, i)} end)
      |> Enum.filter(fn {_i, p} -> p != "" and String.starts_with?(uri, p) end)
      |> Enum.max_by(fn {_i, p} -> byte_size(p) end, fn -> {0, ""} end)

    {code, binary_part(uri, byte_size(prefix), byte_size(uri) - byte_size(prefix))}
  end
end
