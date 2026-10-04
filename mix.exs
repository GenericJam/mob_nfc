defmodule MobNfc.MixProject do
  use Mix.Project

  @source_url "https://github.com/GenericJam/mob_nfc"

  def project do
    [
      app: :mob_nfc,
      version: "0.1.3",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      description: "NFC — NDEF tag read/write for Mob apps (CoreNFC / Android NfcAdapter)",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md"]
      ],
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    # `mix setup` after cloning installs deps and activates the shared git
    # hooks (.githooks): format / Credo --strict / compile run on every push.
    [setup: ["deps.get", "cmd git config core.hooksPath .githooks"]]
  end

  defp deps do
    # :mob is the runtime dep; :mob_dev is test-only (manifest validators) and
    # never ships. Both from Hex so the package builds off this machine + in CI.
    [
      {:mob, "~> 0.7"},
      {:mob_dev, "~> 0.6", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # The native sources + manifest must ship in the package — the host's
      # native build compiles them from deps/<plugin>/priv.
      files: ~w(lib src priv mix.exs README* CHANGELOG*)
    ]
  end
end
