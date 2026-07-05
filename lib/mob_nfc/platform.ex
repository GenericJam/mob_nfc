defmodule MobNfc.Platform do
  @moduledoc false
  # NFC works on iOS (CoreNFC, iPhone 7+) and Android (NfcAdapter). Only the
  # host dev target (no radio) is unsupported. Pure predicate so it's
  # unit-testable without the NIF; the runtime platform comes from
  # :mob_nif.platform/0 (:ios | :android | :host).
  @spec unsupported?(atom()) :: boolean()
  def unsupported?(:host), do: true
  def unsupported?(_), do: false

  @spec current :: atom()
  def current, do: :mob_nif.platform()
end
