defmodule MobNfc.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One read-only native call, no UI, no reader session, no state left behind:
  `:mob_nfc_nif.nfc_available/0`.

    * `true` is `:pass`: the radio is present and enabled. On iOS the answer
      is `NFCNDEFReaderSession.readingAvailable` from the linked Objective-C
      NIF; on Android it is `MobNfcBridge.nfc_state()`, reached through the
      `nativeRegister`-cached method id.
    * `false` is `{:skip, :needs_hardware}`: the same native call answered
      (so the NIF is linked and, on Android, the Kotlin bridge is registered
      and has an Activity), but the device has no NFC radio. iOS simulators
      and Android emulators land here.
    * `:disabled` (Android only: the radio is present but switched off in
      Settings) is a skip whose reason says so: init is proven, but the
      radio can't be exercised until someone turns it on.
    * `{:error, :bridge_not_registered}` (Android: `MobNfcBridge.register()`
      never ran or the `nfc_state` method-id lookup failed),
      `{:error, :no_activity}` (the bootstrap never called `setActivity`),
      and any other answer are failures: the plugin can't work in that host.

  A pass proves the NIF and bridge answer, not that reading works: the iOS
  NFC entitlement and usage string are only checked when a reader session
  begins, which would raise the system sheet, so the test never starts one.

  The host stub's `nif_not_loaded` is a failure too.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(_context) do
    classify(:mob_nfc_nif.nfc_available())
  rescue
    e in ErlangError ->
      if e.original == :nif_not_loaded do
        {:fail, "mob_nfc_nif is not linked into this build: #{Exception.message(e)}"}
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc false
  # The classification of nfc_available/0's answer, split out so every branch
  # is unit-testable without a device.
  @spec classify(term()) :: Mob.Plugin.SelfTest.result()
  def classify(true), do: :pass
  def classify(false), do: {:skip, :needs_hardware}
  def classify(:disabled), do: {:skip, "NFC radio present but switched off in Settings"}

  def classify({:error, :bridge_not_registered}) do
    {:fail,
     "Kotlin MobNfcBridge not registered (nativeRegister never ran or the nfc_state method-id lookup failed)"}
  end

  def classify({:error, :no_activity}) do
    {:fail, "MobNfcBridge has no Activity (MobActivityAware.setActivity never called)"}
  end

  def classify({:error, :no_jni_env}) do
    {:fail, "no JNIEnv could be attached to the calling scheduler thread"}
  end

  def classify({:error, :bridge_exception}) do
    {:fail, "MobNfcBridge.nfc_state() threw (see logcat tag MobNfc)"}
  end

  def classify(other) do
    {:fail, "nfc_available/0 returned #{inspect(other)}, expected true, false or :disabled"}
  end
end
