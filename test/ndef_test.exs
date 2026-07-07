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

  describe "encode/1" do
    test "text_record round-trips through parse + decode_text" do
      bytes = Ndef.encode(Ndef.text_record("hi"))
      [rec] = Ndef.parse(bytes)
      assert Ndef.decode_text(rec) == {:ok, %{text: "hi", lang: "en"}}
    end

    test "text_record honours a non-default language" do
      [rec] = Ndef.parse(Ndef.encode(Ndef.text_record("bonjour", "fr")))
      assert Ndef.decode_text(rec) == {:ok, %{text: "bonjour", lang: "fr"}}
    end

    test "uri_record abbreviates a known prefix and round-trips" do
      rec = Ndef.uri_record("https://mob.dev")
      # 0x04 = "https://", payload is code + "mob.dev"
      assert %{tnf: 1, type: "U", payload: <<0x04, "mob.dev">>} = rec
      [back] = Ndef.parse(Ndef.encode(rec))
      assert Ndef.decode_uri(back) == {:ok, "https://mob.dev"}
    end

    test "uri_record with no known prefix uses code 0" do
      assert %{payload: <<0x00, "xyz://weird">>} = Ndef.uri_record("xyz://weird")
    end

    test "encodes a multi-record message with correct MB/ME flags" do
      bytes = Ndef.encode([Ndef.text_record("a"), Ndef.uri_record("tel:123")])
      # first record: MB set, ME clear (0x91); last: ME set, MB clear (0x51)
      assert <<0x91, _::binary>> = bytes
      assert [%{type: "T"}, %{type: "U"}] = Ndef.parse(bytes)
    end

    test "accepts a bare record (not wrapped in a list)" do
      assert Ndef.encode(Ndef.text_record("x")) == Ndef.encode([Ndef.text_record("x")])
      # single record is both first and last: MB+ME+SR = 0xD1
      assert <<0xD1, _::binary>> = Ndef.encode(Ndef.text_record("x"))
    end

    test "uses the 4-byte length form for payloads over 255 bytes" do
      big = String.duplicate("z", 300)
      bytes = Ndef.encode(Ndef.text_record(big))
      # SR flag must be clear on the (single) record: 0xC1
      assert <<0xC1, _::binary>> = bytes
      [rec] = Ndef.parse(bytes)
      assert Ndef.decode_text(rec) == {:ok, %{text: big, lang: "en"}}
    end
  end
end
