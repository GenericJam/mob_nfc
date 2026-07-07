defmodule MobNfc.HceTest do
  use ExUnit.Case, async: true
  alias MobNfc.Hce

  # A small NDEF message to serve (URI record for https://mob.dev).
  @ndef MobNfc.Ndef.encode(MobNfc.Ndef.uri_record("https://mob.dev"))

  # APDU builders mirroring what a T4T reader (e.g. iOS CoreNFC) sends.
  defp select_aid, do: <<0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01>>
  defp select_file(fid), do: <<0x00, 0xA4, 0x00, 0x0C, 0x02, fid::16>>
  defp read_binary(off, le), do: <<0x00, 0xB0, off::16, le::8>>
  defp update_binary(off, data), do: <<0x00, 0xD6, off::16, byte_size(data)::8, data::binary>>

  # Run a list of APDUs through the responder, collecting {response, event} per step.
  defp run(state, apdus) do
    Enum.map_reduce(apdus, state, fn apdu, st ->
      {resp, st2, event} = Hce.handle_apdu(apdu, st)
      {{resp, event}, st2}
    end)
  end

  describe "SELECT" do
    test "SELECT AID → 9000, nothing selected" do
      assert {<<0x90, 0x00>>, %{selected: :none}, nil} =
               Hce.handle_apdu(select_aid(), Hce.new(@ndef))
    end

    test "SELECT CC (E103) and NDEF (E104) → 9000" do
      s = Hce.new(@ndef)
      assert {<<0x90, 0x00>>, %{selected: :cc}, nil} = Hce.handle_apdu(select_file(0xE103), s)
      assert {<<0x90, 0x00>>, %{selected: :ndef}, nil} = Hce.handle_apdu(select_file(0xE104), s)
    end

    test "SELECT of an unknown file id → 6A82" do
      assert {<<0x6A, 0x82>>, %{selected: :none}, nil} =
               Hce.handle_apdu(select_file(0xBEEF), Hce.new(@ndef))
    end
  end

  describe "Capability Container" do
    test "read-only tag advertises write-access FF" do
      assert <<_::binary-size(14), 0xFF>> = Hce.cc(false)
      assert byte_size(Hce.cc(false)) == 15
    end

    test "writable tag advertises write-access 00" do
      assert <<_::binary-size(14), 0x00>> = Hce.cc(true)
    end

    test "READ BINARY of the CC returns the 15 CC bytes + 9000" do
      s = %{Hce.new(@ndef) | selected: :cc}
      {resp, _s, event} = Hce.handle_apdu(read_binary(0, 15), s)
      assert resp == Hce.cc(false) <> <<0x90, 0x00>>
      assert event == nil
    end
  end

  describe "READ BINARY of the NDEF file" do
    test "returns NLEN + message and fires :read once the end is reached" do
      s = %{Hce.new(@ndef) | selected: :ndef}
      file = Hce.ndef_file(@ndef)
      {resp, _s, event} = Hce.handle_apdu(read_binary(0, byte_size(file)), s)
      assert resp == file <> <<0x90, 0x00>>
      assert event == :read
    end

    test "a partial read (not to the end) does not fire :read" do
      s = %{Hce.new(@ndef) | selected: :ndef}
      {resp, _s, event} = Hce.handle_apdu(read_binary(0, 2), s)
      assert resp == <<byte_size(@ndef)::16, 0x90, 0x00>>
      assert event == nil
    end

    test "reading NLEN (offset 0, le 2) then the message (offset 2) reconstructs it" do
      s = %{Hce.new(@ndef) | selected: :ndef}
      {<<nlen::16, 0x90, 0x00>>, _, _} = Hce.handle_apdu(read_binary(0, 2), s)

      {<<msg::binary-size(^nlen), 0x90, 0x00>>, _, :read} =
        Hce.handle_apdu(read_binary(2, nlen), s)

      assert msg == @ndef

      assert {:ok, "https://mob.dev"} =
               msg |> MobNfc.Ndef.parse() |> hd() |> MobNfc.Ndef.decode_uri()
    end

    test "READ BINARY with nothing selected → 6A82" do
      assert {<<0x6A, 0x82>>, _, nil} = Hce.handle_apdu(read_binary(0, 15), Hce.new(@ndef))
    end

    test "READ BINARY past the end of the file → 6F00" do
      s = %{Hce.new(@ndef) | selected: :ndef}
      big_offset = byte_size(Hce.ndef_file(@ndef)) + 1
      assert {<<0x6F, 0x00>>, _, nil} = Hce.handle_apdu(read_binary(big_offset, 1), s)
    end
  end

  describe "a full reader read sequence" do
    test "SELECT AID → SELECT CC → READ CC → SELECT NDEF → READ NDEF" do
      msg = MobNfc.Ndef.encode(MobNfc.Ndef.text_record("hi"))

      apdus = [
        select_aid(),
        select_file(0xE103),
        read_binary(0, 15),
        select_file(0xE104),
        read_binary(0, byte_size(Hce.ndef_file(msg)))
      ]

      {steps, _final} = run(Hce.new(msg), apdus)
      events = Enum.map(steps, &elem(&1, 1))
      # Only the final NDEF read yields :read.
      assert events == [nil, nil, nil, nil, :read]
      {ndef_resp, :read} = List.last(steps)
      assert ndef_resp == Hce.ndef_file(msg) <> <<0x90, 0x00>>
    end
  end

  describe "UPDATE BINARY (writable tag)" do
    test "a write to a read-only tag is rejected with 6A82" do
      s = %{Hce.new(@ndef, false) | selected: :ndef}
      assert {<<0x6A, 0x82>>, _, nil} = Hce.handle_apdu(update_binary(0, <<0x00, 0x00>>), s)
    end

    test "an iOS-style write sequence (NLEN=0, message, NLEN=len) yields {:written, msg}" do
      new_msg = MobNfc.Ndef.encode(MobNfc.Ndef.text_record("hello from mob"))
      nlen = byte_size(new_msg)
      s = %{Hce.new(<<>>, true) | selected: :ndef}

      apdus = [
        update_binary(0, <<0x00, 0x00>>),
        update_binary(2, new_msg),
        update_binary(0, <<nlen::16>>)
      ]

      {steps, _final} = run(s, apdus)
      events = Enum.map(steps, &elem(&1, 1))
      assert [nil, nil, {:written, written}] = events
      assert written == new_msg

      assert {:ok, %{text: "hello from mob"}} =
               written |> MobNfc.Ndef.parse() |> hd() |> MobNfc.Ndef.decode_text()

      assert Enum.all?(steps, fn {resp, _} -> resp == <<0x90, 0x00>> end)
    end

    test "writing NLEN and message in a single UPDATE also completes" do
      new_msg = MobNfc.Ndef.encode(MobNfc.Ndef.uri_record("tel:123"))
      s = %{Hce.new(<<>>, true) | selected: :ndef}

      {<<0x90, 0x00>>, _s, {:written, written}} =
        Hce.handle_apdu(update_binary(0, <<byte_size(new_msg)::16>> <> new_msg), s)

      assert written == new_msg
    end

    test "an over-capacity write is rejected with 6F00" do
      s = %{Hce.new(<<>>, true) | selected: :ndef}
      # capacity is 1024; offset 1020 + 8 bytes overflows
      assert {<<0x6F, 0x00>>, _, nil} = Hce.handle_apdu(update_binary(1020, <<0::8*8>>), s)
    end

    test "UPDATE BINARY when the NDEF file isn't selected is rejected" do
      s = %{Hce.new(<<>>, true) | selected: :cc}
      assert {<<0x6A, 0x82>>, _, nil} = Hce.handle_apdu(update_binary(0, <<0x00, 0x00>>), s)
    end
  end

  describe "unknown / malformed commands" do
    test "an unknown instruction → 6D00" do
      assert {<<0x6D, 0x00>>, _, nil} =
               Hce.handle_apdu(<<0x00, 0xC0, 0x00, 0x00>>, Hce.new(@ndef))
    end

    test "a truncated APDU → 6D00" do
      assert {<<0x6D, 0x00>>, _, nil} = Hce.handle_apdu(<<0x00>>, Hce.new(@ndef))
    end
  end
end
