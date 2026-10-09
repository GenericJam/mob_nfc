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
      and has an Activity), but the device has no NFC radio or it is
      switched off. iOS simulators and Android emulators land here.
    * `{:error, :bridge_not_registered}` (Android: `MobNfcBridge.register()`
      never ran or the `nfc_state` method-id lookup failed),
      `{:error, :no_activity}` (the bootstrap never called `setActivity`),
      and any other answer are failures: the plugin can't work in that host.

  The host stub's `nif_not_loaded` is a failure too.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(_context) do
    classify(:mob_nfc_nif.nfc_available())
  rescue
    e in ErlangError ->
      {:fail, "mob_nfc_nif is not linked into this build: #{Exception.message(e)}"}
  end

  @doc false
  # The classification of nfc_available/0's answer, split out so every branch
  # is unit-testable without a device.
  @spec classify(term()) :: Mob.Plugin.SelfTest.result()
  def classify(true), do: :pass
  def classify(false), do: {:skip, :needs_hardware}

  def classify({:error, :bridge_not_registered}) do
    {:fail,
     "Kotlin MobNfcBridge not registered (nativeRegister never ran or the nfc_state method-id lookup failed)"}
  end

  def classify({:error, :no_activity}) do
    {:fail, "MobNfcBridge has no Activity (MobActivityAware.setActivity never called)"}
  end

  def classify(other) do
    {:fail, "nfc_available/0 returned #{inspect(other)}, expected true or false"}
  end
end
