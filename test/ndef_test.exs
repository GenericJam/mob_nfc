defmodule MobNfc.NdefTest do
  use ExUnit.Case, async: true
  alias MobNfc.Ndef

  # A Well-Known Text record "en" / "hi" as a Short Record, single message
  # (MB+ME+SR flags = 0xD1, TNF 1). type_len=1 ("T"), payload = status(0x02)
  # + "en" + "hi".
  @text_msg <<0xD1, 0x01, 0x05, ?T, 0x02, ?e, ?n, ?h, ?i>>

  # A Well-Known URI record with prefix code 0x04 ("https://") + "mob.dev".
  @uri_msg <<0xD1, 0x01, 0x08, ?U, 0x04, "mob.dev">>

  describe "parse/1" do
    test "parses a Text record's raw fields" do
      assert [%{tnf: 1, type: "T", id: "", payload: <<0x02, "enhi">>}] = Ndef.parse(@text_msg)
    end

    test "parses two records in one message" do
      assert [%{type: "T"}, %{type: "U"}] = Ndef.parse(@text_msg <> @uri_msg)
    end

    test "returns [] on empty or malformed input" do
      assert Ndef.parse(<<>>) == []
      assert Ndef.parse("not ndef at all really") |> is_list()
      assert Ndef.parse(:not_binary) == []
      # truncated payload -> keep what parsed (nothing here)
      assert Ndef.parse(<<0xD1, 0x01, 0x05, ?T>>) == []
    end

    test "handles a 4-byte (non-short) payload length" do
      # SR flag cleared (0xC1), 4-byte payload length = 2
      msg = <<0xC1, 0x01, 0::32-signed, ?T>> |> binary_part(0, 3)
      # build properly: flags=0xC1, type_len=1, payload_len=2 (4 bytes), type "T", payload "hi"
      full = <<0xC1, 0x01, 0, 0, 0, 2, ?T, ?h, ?i>>
      assert [%{type: "T", payload: "hi"}] = Ndef.parse(full)
      _ = msg
    end
  end

  describe "decode_text/1" do
    test "decodes text + language" do
      [rec] = Ndef.parse(@text_msg)
      assert Ndef.decode_text(rec) == {:ok, %{text: "hi", lang: "en"}}
    end

    test ":error for a non-text record" do
      [rec] = Ndef.parse(@uri_msg)
      assert Ndef.decode_text(rec) == :error
    end
  end

  describe "decode_uri/1" do
    test "expands the abbreviation prefix" do
      [rec] = Ndef.parse(@uri_msg)
      assert Ndef.decode_uri(rec) == {:ok, "https://mob.dev"}
    end

    test "prefix code 0 is no prefix" do
      msg = <<0xD1, 0x01, 0x0D, ?U, 0x00, "https://x.io">>
      [rec] = Ndef.parse(msg)
      assert Ndef.decode_uri(rec) == {:ok, "https://x.io"}
    end

    test ":error for a non-uri record" do
      [rec] = Ndef.parse(@text_msg)
      assert Ndef.decode_uri(rec) == :error
    end
  end
end
