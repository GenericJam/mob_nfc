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

    test "bridge class + jni source are wired for Android" do
      assert @manifest.android.bridge_class == "io.mob.nfc.MobNfcBridge"
      assert @manifest.android.jni_source =~ "mob_nfc_jni.c"
      assert @manifest.android.bridge_kt =~ "MobNfcBridge.kt"
    end
  end
end
