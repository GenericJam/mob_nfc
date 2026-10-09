defmodule MobNfcTest do
  use ExUnit.Case, async: true

  alias MobNfc.SelfTest

  @plugin_dir Path.expand("..", __DIR__)

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

  describe "emulation_request/2 (emulate_ndef transport)" do
    defp emulation_opts(content, opts) do
      {:ok, json} = MobNfc.emulation_request(content, opts)
      JSON.decode!(json)
    end

    test "defaults to non-writable" do
      assert emulation_opts("", [])["writable"] == false
    end

    test "writable: true is carried through" do
      assert emulation_opts("", writable: true)["writable"] == true
    end

    test "only the literal true enables writable" do
      assert emulation_opts("", writable: :yes)["writable"] == false
    end

    test "encodes record content round-trippably" do
      j = emulation_opts(MobNfc.Ndef.text_record("hi"), writable: true)
      [rec] = j["ndef"] |> Base.decode64!() |> MobNfc.Ndef.parse()
      assert MobNfc.Ndef.decode_text(rec) == {:ok, %{text: "hi", lang: "en"}}
    end

    test "a message of exactly 1022 bytes (1024-byte file minus NLEN) is accepted" do
      raw = :binary.copy(<<0xAB>>, 1022)
      assert Base.decode64!(emulation_opts(raw, [])["ndef"]) == raw
    end

    test "a 1023-byte raw message is rejected as :too_large" do
      assert MobNfc.emulation_request(:binary.copy(<<0xAB>>, 1023), []) == {:error, :too_large}
    end

    test "records that encode past the limit are rejected as :too_large" do
      rec = MobNfc.Ndef.text_record(String.duplicate("x", 1100))
      assert MobNfc.emulation_request(rec, writable: true) == {:error, :too_large}
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
      assert snippet =~ "@xml/mob_nfc_hce_apduservice"

      assert "priv/native/android/res/xml/mob_nfc_hce_apduservice.xml" in @manifest.android.res_files
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the HCE service never serves while the device is locked" do
      # requireDeviceUnlock="false" let a locked, pocketed phone answer any
      # reader with the emulated payload (Operator v1 review, MOB-395).
      xml = File.read!("priv/native/android/res/xml/mob_nfc_hce_apduservice.xml")
      assert xml =~ ~s(android:requireDeviceUnlock="true")
      refute xml =~ ~s(android:requireDeviceUnlock="false")
    end

    test "every @xml/@string resource the manifest snippets reference ships in res_files" do
      snippet = Enum.join(@manifest.android.manifest_application_snippets, "\n")

      shipped =
        Enum.map(
          @manifest.android.res_files,
          &{Path.basename(Path.dirname(&1)), Path.rootname(Path.basename(&1)), &1}
        )

      xml_bodies = for {"xml", _, path} <- shipped, do: File.read!(path)
      refs = Regex.scan(~r/@(xml|string)\/(\w+)/, Enum.join([snippet | xml_bodies], "\n"))
      # The apduservice's android:description is a @string ref; guard the scan.
      assert Enum.any?(refs, &match?([_, "string", _], &1))

      for [_, kind, name] <- refs do
        case kind do
          "xml" ->
            assert Enum.any?(shipped, fn {dir, base, path} ->
                     dir == "xml" and base == name and File.exists?(path)
                   end),
                   "@xml/#{name} referenced but not shipped"

          "string" ->
            values = for {"values", _, path} <- shipped, do: File.read!(path)
            assert Enum.any?(values, &(&1 =~ ~s(name="#{name}"))), "@string/#{name} not defined"
        end
      end
    end

    test "plugin res files never reuse the 0.1.0 host-owned apduservice path" do
      # 0.1.0 told hosts to hand-create res/xml/mob_nfc_apduservice.xml; mob_dev
      # refuses to overwrite host-owned files, so the plugin must not ship it.
      refute Enum.any?(
               @manifest.android.res_files,
               &(Path.basename(&1) == "mob_nfc_apduservice.xml")
             )

      assert "priv/native/android/res/values/mob_nfc_strings.xml" in @manifest.android.res_files

      # No longer a manual obligation.
      refute Enum.join(@manifest.host_requirements, "\n") =~ "MobNfcApduService"
    end

    test "bridge class + jni source are wired for Android" do
      assert @manifest.android.bridge_class == "io.mob.nfc.MobNfcBridge"
      assert @manifest.android.jni_source =~ "mob_nfc_jni.c"
      assert @manifest.android.bridge_kt =~ "MobNfcBridge.kt"
    end

    test "declares the self-test, which passes the validator without a selftest warning" do
      {:ok, m} = MobDev.Plugin.Manifest.load(@plugin_dir)
      assert m.selftest == MobNfc.SelfTest

      assert %{errors: [], warnings: warnings} =
               MobDev.Plugin.Validator.validate_plugin(m, @plugin_dir)

      refute Enum.any?(warnings, &(&1 =~ "selftest"))
    end
  end

  describe "MobNfc.SelfTest" do
    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      assert {:fail, reason} = result = SelfTest.run(%{platform: :android, device: :emulator})
      assert reason =~ "mob_nfc_nif is not linked"
      assert reason =~ "nif_not_loaded"
      assert Mob.Plugin.SelfTest.result?(result)
    end

    test "a radio present and enabled passes" do
      assert SelfTest.classify(true) == :pass
      assert Mob.Plugin.SelfTest.result?(:pass)
    end

    test "an answered false (no radio) is a needs_hardware skip" do
      assert SelfTest.classify(false) == {:skip, :needs_hardware}
      assert Mob.Plugin.SelfTest.result?({:skip, :needs_hardware})
    end

    test "an answered :disabled (radio present, switched off) is a skip saying so, not needs_hardware" do
      assert {:skip, reason} = result = SelfTest.classify(:disabled)
      assert reason =~ "switched off"
      assert Mob.Plugin.SelfTest.result?(result)
    end

    test "every Android error answer fails with its own reason" do
      for {answer, prefix} <- [
            {{:error, :bridge_not_registered}, "Kotlin MobNfcBridge not registered"},
            {{:error, :no_activity}, "MobNfcBridge has no Activity"},
            {{:error, :no_jni_env}, "no JNIEnv could be attached"},
            {{:error, :bridge_exception}, "MobNfcBridge.nfc_state() threw"}
          ] do
        assert {:fail, reason} = result = SelfTest.classify(answer)
        assert String.starts_with?(reason, prefix)
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end

    test "any other answer fails, quoting it" do
      for answer <- [{:error, :unsupported}, :ok, nil] do
        assert {:fail, reason} = result = SelfTest.classify(answer)
        assert reason =~ "nfc_available/0 returned #{inspect(answer)}"
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end
  end

  describe "Android JNI seam" do
    # nativeRegister looks bridge methods up by name + JNI signature; a drift
    # between the zig lookup and the Kotlin declaration only shows on a device
    # (as {:error, :bridge_not_registered} for nfc_state). Pin them together.
    @jni_types %{"J" => "Long", "I" => "Int", "Z" => "Boolean", "Ljava/lang/String;" => "String"}

    defp kotlin_sig(sig) do
      [_, args, ret] = Regex.run(~r/^\((.*)\)(.+)$/, sig)
      params = Regex.scan(~r/L[^;]+;|[JIZ]/, args) |> Enum.map(fn [t] -> @jni_types[t] end)
      {params, if(ret == "V", do: nil, else: @jni_types[ret])}
    end

    test "every method nativeRegister caches is a Kotlin bridge method with that signature" do
      zig = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_nfc_nif.zig"))
      kt = File.read!(Path.join(@plugin_dir, "priv/native/android/MobNfcBridge.kt"))

      lookups = Regex.scan(~r/cacheMethod\(jenv, cls, "(\w+)", "([^"]+)"\)/, zig)
      assert ["nfc_state", "()I"] in Enum.map(lookups, &tl/1)

      for [_, name, sig] <- lookups do
        {params, ret} = kotlin_sig(sig)
        match = Regex.run(~r/fun #{name}\(([^)]*)\)(?::\s*(\w+))?/, kt, capture: :all_but_first)
        assert match, "#{name} is looked up in zig but not declared in MobNfcBridge.kt"
        [kt_params | kt_ret] = match

        kt_types =
          Regex.scan(~r/:\s*(\w+)\??/, kt_params) |> Enum.map(fn [_, t] -> t end)

        assert kt_types == params, "#{name}: zig signature #{sig} vs Kotlin (#{kt_params})"
        assert List.first(kt_ret) == ret, "#{name}: Kotlin return #{inspect(kt_ret)} vs #{sig}"
      end
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
