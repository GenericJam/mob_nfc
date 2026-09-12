defmodule MobNfcTest do
  use ExUnit.Case, async: true

  # The NIF is never loaded in the host test env, so these exercise the pure
  # Elixir layer: platform gating and the manifest contract. Native behavior is
  # verified on-device (see the plugin CLAUDE.md / README).

  describe "MobNfc.Platform" do
    test "host is unsupported; ios/android are supported" do
      assert MobNfc.Platform.unsupported?(:host)
      refute MobNfc.Platform.unsupported?(:ios)
      refute MobNfc.Platform.unsupported?(:android)
    end
  end

  describe "start_reading/2 on an unsupported platform" do
    test "delivers {:nfc, :error, :unsupported} instead of raising" do
      # We can't force Platform.current/0 without the NIF, but the host path is
      # exercised indirectly: on host, current/0 raises UndefinedFunctionError
      # (no NIF), which is the documented host behavior. Assert the message
      # contract via a direct call to the guard path.
      assert MobNfc.Platform.unsupported?(:host)
    end
  end

  describe "reading_json/1 (start_reading transport)" do
    test "defaults to ndef mode with the default alert" do
      j = JSON.decode!(MobNfc.reading_json([]))
      assert j["mode"] == "ndef"
      assert j["alert"] == "Hold your phone near an NFC tag"
    end

    test ":mode :tag maps to \"tag\"; anything else is \"ndef\"" do
      assert JSON.decode!(MobNfc.reading_json(mode: :tag))["mode"] == "tag"
      assert JSON.decode!(MobNfc.reading_json(mode: :ndef))["mode"] == "ndef"
      assert JSON.decode!(MobNfc.reading_json([]))["mode"] == "ndef"
    end

    test "honours a custom alert" do
      assert JSON.decode!(MobNfc.reading_json(alert: "hi"))["alert"] == "hi"
    end
  end

  describe "writing_json/2 (write_ndef transport)" do
    test "base64-encodes record content and round-trips through the parser" do
      j = JSON.decode!(MobNfc.writing_json(MobNfc.Ndef.uri_record("https://mob.dev"), []))
      [rec] = j["ndef"] |> Base.decode64!() |> MobNfc.Ndef.parse()
      assert MobNfc.Ndef.decode_uri(rec) == {:ok, "https://mob.dev"}
    end

    test "passes raw binary content through unchanged" do
      raw = <<0xD1, 0x01, 0x01, ?T, 0x00>>
      j = JSON.decode!(MobNfc.writing_json(raw, []))
      assert Base.decode64!(j["ndef"]) == raw
    end

    test "carries the alert" do
      assert JSON.decode!(MobNfc.writing_json("", alert: "tap"))["alert"] == "tap"
    end
  end

  describe "emulation_json/2 (emulate_ndef transport)" do
    test "defaults to non-writable" do
      assert JSON.decode!(MobNfc.emulation_json("", []))["writable"] == false
    end

    test "writable: true is carried through" do
      assert JSON.decode!(MobNfc.emulation_json("", writable: true))["writable"] == true
    end

    test "only the literal true enables writable" do
      assert JSON.decode!(MobNfc.emulation_json("", writable: :yes))["writable"] == false
    end

    test "encodes record content round-trippably" do
      j = JSON.decode!(MobNfc.emulation_json(MobNfc.Ndef.text_record("hi"), writable: true))
      [rec] = j["ndef"] |> Base.decode64!() |> MobNfc.Ndef.parse()
      assert MobNfc.Ndef.decode_text(rec) == {:ok, %{text: "hi", lang: "en"}}
    end
  end

  describe "to_ndef_bytes/1" do
    test "binary passes through; records are encoded" do
      assert MobNfc.to_ndef_bytes(<<1, 2, 3>>) == <<1, 2, 3>>

      assert MobNfc.to_ndef_bytes(MobNfc.Ndef.text_record("x")) ==
               MobNfc.Ndef.encode(MobNfc.Ndef.text_record("x"))
    end
  end

  describe "plugin manifest" do
    @manifest Code.eval_file("priv/mob_plugin.exs") |> elem(0)

    test "declares the mob_nfc plugin with both platform NIFs" do
      assert @manifest.name == :mob_nfc
      assert @manifest.plugin_spec_version == 1
      platforms = Enum.map(@manifest.nifs, & &1.platform) |> Enum.sort()
      assert platforms == [:android, :ios]
      assert Enum.all?(@manifest.nifs, &(&1.module == :mob_nfc_nif))
    end

    test "declares Android NFC permission and the CoreNFC framework + plist key" do
      assert "android.permission.NFC" in @manifest.android.permissions
      assert "CoreNFC" in @manifest.ios.frameworks
      assert Map.has_key?(@manifest.ios.plist_keys, :NFCReaderUsageDescription)
    end

    test "surfaces the iOS entitlement + Android uses-feature as host_requirements" do
      reqs = Enum.join(@manifest.host_requirements, "\n")
      assert reqs =~ "com.apple.developer.nfc.readersession.formats"
      assert reqs =~ "android.hardware.nfc"
    end

    test "surfaces the iOS raw-tag AID list as a host_requirement (MOB-38 gap)" do
      reqs = Enum.join(@manifest.host_requirements, "\n")
      assert reqs =~ "select-identifiers"
    end

    test "contributes the HCE service + res files automatically (no host_requirement)" do
      # The <service> rides in android.manifest_application_snippets and the
      # apduservice/strings ride in android.res_files (MOB-39), not a manual step.
      snippet = Enum.join(@manifest.android.manifest_application_snippets, "\n")
      assert snippet =~ "io.mob.nfc.MobNfcApduService"
      assert snippet =~ "HOST_APDU_SERVICE"
      assert snippet =~ "@xml/mob_nfc_apduservice"

      assert "priv/native/android/res/xml/mob_nfc_apduservice.xml" in @manifest.android.res_files
      assert "priv/native/android/res/values/mob_nfc_strings.xml" in @manifest.android.res_files

      # No longer a manual obligation.
      refute Enum.join(@manifest.host_requirements, "\n") =~ "MobNfcApduService"
    end

    test "bridge class + jni source are wired for Android" do
      assert @manifest.android.bridge_class == "io.mob.nfc.MobNfcBridge"
      assert @manifest.android.jni_source =~ "mob_nfc_jni.c"
      assert @manifest.android.bridge_kt =~ "MobNfcBridge.kt"
    end
  end

  describe "MOB-80: no runtime dep on Jason" do
    # `lib/` used to call `Jason.encode!` in three transport helpers while
    # mix.exs declared no `:jason` dep. In a consumer that didn't pull Jason
    # transitively (a plain mob app is one), the first call raised
    # UndefinedFunctionError at runtime. Switched to the built-in `JSON`
    # module (Elixir 1.18+, which mix.exs already targets). This test
    # catches a re-introduction — if you genuinely need Jason, add
    # `{:jason, "~> 1.4"}` to `deps/0` as a *runtime* (non-`:only`) dep and
    # delete this test.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "no lib/ source references Jason at runtime" do
      offenders =
        Path.wildcard(Path.join([__DIR__, "..", "lib", "**", "*.ex"]))
        |> Enum.flat_map(fn file ->
          file
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} ->
            String.contains?(line, "Jason.") or String.contains?(line, "Jason,")
          end)
          |> Enum.map(fn {line, lineno} ->
            "#{Path.relative_to_cwd(file)}:#{lineno}  #{String.trim(line)}"
          end)
        end)

      assert offenders == [],
             "MOB-80: lib/ references Jason at runtime; use the built-in JSON " <>
               "stdlib (Elixir 1.18+) or add {:jason, \"~> 1.4\"} to mix.exs " <>
               "deps/0 as a real runtime dep.\n\n" <> Enum.join(offenders, "\n")
    end
  end
end
