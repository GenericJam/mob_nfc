# mob_nfc plugin manifest.
#
# NFC — NDEF tag read/write. iOS CoreNFC (NFCNDEFReaderSession, iPhone 7+);
# Android NfcAdapter reader mode (enableReaderMode). Card emulation (HCE) is a
# future addition, not in this manifest.
#
# The iOS entitlement (com.apple.developer.nfc.readersession.formats) can NOT be
# contributed by a plugin today — mob_dev has no entitlement-merge path (see
# MOB-37). It is surfaced below as a host_requirement so `mix mob.deploy
# --native` nags until the host adds it to ios/<app>.entitlements. Same for the
# Android <uses-feature> + tag intent-filter, which have no first-class manifest
# field.
%{
  name: :mob_nfc,
  mob_version: "~> 0.7",
  plugin_spec_version: 1,
  description: "NFC — NDEF tag read/write via CoreNFC / Android NfcAdapter",
  nifs: [
    # Android: zig NIF under this module — nfc_* bridging to the Kotlin
    # MobNfcBridge (NfcAdapter reader mode). `mob_nfc_nif_nif_init` is the
    # static init symbol. platform: :android so the iOS build skips it.
    %{module: :mob_nfc_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android},
    # iOS: same NIF module name, ObjC over CoreNFC (NFCNDEFReaderSession).
    # platform: :ios so Android skips it; the two share the erl stub and the
    # Elixir layer gates per platform (host has no radio).
    %{module: :mob_nfc_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}
  ],
  android: %{
    # NFC is an install-time (normal) permission — no runtime dialog — so it
    # needs no core permission-registry capability entry.
    permissions: ["android.permission.NFC"],
    # Plain JNI-thunk C (Java_io_mob_nfc_*) compiled via -Dplugin_jni_sources
    # alongside beam_jni.c — the nativeDeliverNfc* thunks that call the plugin
    # NIF's mob_deliver_nfc_* exports.
    jni_source: "priv/native/jni/mob_nfc_jni.c",
    # Plugin-owned Kotlin bridge (own package, NOT the app's MobBridge). mob_dev
    # copies it into the app Kotlin sourceSet and generates
    # MobPluginBootstrap.registerAll() to call MobNfcBridge.register() at
    # startup, which caches the jclass + nfc_* method ids natively.
    bridge_kt: "priv/native/android/MobNfcBridge.kt",
    bridge_class: "io.mob.nfc.MobNfcBridge"
  },
  ios: %{
    frameworks: ["CoreNFC"],
    plist_keys: %{
      NFCReaderUsageDescription:
        "NFC access is required to read and write nearby tags."
      # NOTE: raw-tag mode (`MobNfc.start_reading(mode: :tag)`, iOS
      # NFCTagReaderSession) also needs the *array-valued* Info.plist key
      # com.apple.developer.nfc.readersession.iso7816.select-identifiers, but
      # mob_dev's plugin plist merge only supports scalar (string/integer)
      # values today (see MOB-38), so it can't be declared here — it's surfaced
      # as a host_requirement below.
    }
  },
  # Obligations the manifest schema can't express yet (see MOB-37 for the iOS
  # entitlement one). Printed on every `mix mob.deploy --native`.
  host_requirements: [
    "iOS: add the NFC entitlement to ios/<app>.entitlements and provision an " <>
      "NFC-capable profile (`mix mob.provision`):\n" <>
      "    <key>com.apple.developer.nfc.readersession.formats</key>\n" <>
      "    <array><string>NDEF</string><string>TAG</string></array>",
    "Android: add to AndroidManifest.xml so flash-less/NFC-less devices still " <>
      "install and background tag dispatch works:\n" <>
      "    <uses-feature android:name=\"android.hardware.nfc\" android:required=\"false\"/>",
    "iOS raw-tag mode (start_reading(mode: :tag)) needs an ISO7816 AID list in " <>
      "ios/<app>.plist (mob_dev can't merge array plist keys yet — MOB-38):\n" <>
      "    <key>com.apple.developer.nfc.readersession.iso7816.select-identifiers</key>\n" <>
      "    <array><string>D2760000850101</string> <!-- NFC Forum Type 4 (NDEF) -->\n" <>
      "           <string>325041592E5359532E4444463031</string> <!-- PPSE --></array>\n" <>
      "  Add the specific AIDs of the ISO7816 tags you intend to read. iOS blocks " <>
      "EMV payment cards regardless (reserved for the Secure Element)."
  ]
}
