defmodule NervesPhone.MixProject do
  use Mix.Project

  @app :nerves_phone
  @version "0.1.0"
  @all_targets [:fp3]

  # Deterministic builds — same input, same firmware bytes.
  System.put_env("ERL_COMPILER_OPTIONS", "deterministic")

  # Bundlex (Membrane's native builds) archives with a plain `ar`, which on
  # a Mac drops the target's objects. See scripts/cross-ar/ar.
  cross_ar = Path.expand("scripts/cross-ar", __DIR__)

  if Mix.target() != :host and not String.contains?(System.get_env("PATH", ""), cross_ar) do
    System.put_env("PATH", cross_ar <> ":" <> System.get_env("PATH", ""))
  end

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.19",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {NervesPhone.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets] ++ target_applications(Mix.target())
    ]
  end

  defp target_applications(:host), do: []

  defp target_applications(_target) do
    [
      # Nerves runtime stack
      :nerves_pack,
      # FP3-specific userspace daemons
      :ex_rmtfs,
      :ex_remoteproc,
      :ex_qcom_smgr,
      :ex_qbootctl,
      :ex_audio,
      :fp3_camera,
      :vintage_net_qmi,
      :fp3_modem,
      :ex_nfc,
      :ex_location,
      # The AI stack: this pulls arm_ai, nx_arm, infer_*, nerves_model_hub,
      # cpu_governor, nerves_data_resize via nerves_ai's mix.exs.
      :nerves_ai
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # ---------------- Dependencies for all targets ----------------
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},
      {:nerves_uevent, "~> 0.1.7", override: true},

      # UI: Emerge renders the declarative UI (DRM/OpenGL on the phone, a
      # window on the host) and Solve holds the application state.
      {:emerge, "~> 0.4.2"},
      {:solve, "~> 0.3.1"},

      # Time zones, for the apps' schedule (NervesPhone.Schedule).
      {:tz, "~> 0.28.4"},

      # Media pipelines (audio now, video later), played through PortAudio.
      {:membrane_core, "~> 1.2"},
      {:membrane_raw_audio_format, "~> 0.12.0"},
      {:membrane_portaudio_plugin, "~> 0.19.6"},

      # Video playback (NervesPhone.Video.Player): files, MP4, H.264 through
      # the Venus hardware decoder, AAC, and frames to Emerge.
      {:membrane_file_plugin, "~> 0.17.5"},
      {:membrane_mp4_plugin, "~> 0.36.10"},
      {:membrane_h26x_plugin, "~> 0.11.2", targets: @all_targets},
      {:membrane_aac_plugin, "~> 0.19.4", targets: @all_targets},
      {:membrane_aac_fdk_plugin, "~> 0.19.0", targets: @all_targets},
      {:membrane_video_interop, "~> 0.1.1", targets: @all_targets},
      {:membrane_v4l2_decoder, path: "../membrane_v4l2_decoder", targets: @all_targets},

      # Embedded Python, for svtplay-dl and yt-dlp (see NervesPhone.Python).
      {:pythonx, "~> 0.4.10"},

      # Reads Anki decks (.apkg), which are SQLite inside (see
      # NervesPhone.Flashcards.Apkg).
      {:exqlite, "~> 0.41.0"},

      # Runs tailscaled (see NervesPhone.Tailscale).
      {:muontrap, "~> 1.8"},

      # The QR code for logging in to Tailscale from Settings.
      {:eqrcode, "~> 0.2.1"},

      # ---------------- Dependencies for all targets except :host ----------------
      {:nerves_pack, "~> 0.7", targets: @all_targets},
      {:nerves_time, "~> 0.4", targets: @all_targets},
      {:vintage_net, "~> 0.13", targets: @all_targets},
      {:vintage_net_ethernet, "~> 0.11", targets: @all_targets},

      # Touchscreen and buttons (Linux input events)
      {:input_event, "~> 1.4", targets: @all_targets},

      # ---------------- AI stack ----------------
      # nerves_ai pulls arm_ai (whose NIF builds from source with Rust),
      # nx_arm, the infer_* libraries and the boot helpers.
      {:nerves_ai, github: "mlainez/nerves_ai", override: true, targets: @all_targets},

      # ---------------- FP3 hardware userspace ----------------
      {:ex_rmtfs, github: "mlainez/ex_rmtfs", targets: @all_targets},
      {:ex_remoteproc, github: "mlainez/ex_remoteproc", override: true, targets: @all_targets},
      {:ex_qcom_smgr, github: "mlainez/ex_qcom_smgr", override: true, targets: @all_targets},
      {:ex_qbootctl, github: "mlainez/ex_qbootctl", override: true, targets: @all_targets},
      {:ex_audio, github: "mlainez/ex_audio", override: true, targets: @all_targets},
      {:fp3_camera, github: "mlainez/fp3_camera", override: true, targets: @all_targets},
      {:qmi,
       github: "mlainez/qmi", branch: "qrtr-transport", override: true, targets: @all_targets},
      {:vintage_net_qmi,
       github: "mlainez/vintage_net_qmi",
       branch: "qrtr-transport",
       override: true,
       targets: @all_targets},
      {:fp3_modem, github: "mlainez/fp3_modem", override: true, targets: @all_targets},
      {:ex_nfc, github: "mlainez/ex_nfc", override: true, targets: @all_targets},
      {:ex_location, github: "mlainez/ex_location", override: true, targets: @all_targets},
      {:blue_heron, github: "mlainez/blue_heron", targets: @all_targets},

      # ---------------- The Nerves system ----------------
      # The prebuilt system comes from the tag's GitHub release.
      {:nerves_system_fp3,
       github: "mlainez/nerves_system_fp3", tag: "v0.2.2", runtime: false, targets: :fp3}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is not started automatically.
      # See https://nerves-pack.hexdocs.pm/readme.html#erlang-distribution
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [
        &Nerves.Release.init/1,
        &vendor_python/1,
        :assemble,
        &drop_foreign_nifs/1,
        &drop_foreign_python/1,
        &add_tailscale/1,
        &trim_portaudio/1
      ],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  # Every build shares deps/emerge/priv, so it collects Emerge's NIF for each
  # platform it was compiled for (macOS for tests, aarch64 Linux for the
  # phone). Keep only the target's in the release.
  defp drop_foreign_nifs(%Mix.Release{} = release) do
    if Mix.target() != :host do
      release.path
      |> Path.join("lib/emerge-*/priv/native/libemerge_skia-*.so")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "-linux-"))
      |> Enum.each(&File.rm!/1)
    end

    release
  end

  # Downloads the target's Python into priv before it's copied into the
  # release, when it's missing or the pins in `mix python.vendor` changed.
  defp vendor_python(%Mix.Release{} = release) do
    if not Mix.Tasks.Python.Vendor.up_to_date?(), do: Mix.Task.run("python.vendor")
    release
  end

  # Like the NIFs, priv/python collects a Python for each target that
  # `mix python.vendor` ran for. Keep only the target's.
  defp drop_foreign_python(%Mix.Release{} = release) do
    release.path
    |> Path.join("lib/nerves_phone-*/priv/python/*")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == to_string(Mix.target())))
    |> Enum.each(&File.rm_rf!/1)

    release
  end

  # Tailscale isn't in the Nerves system, so its static build goes into
  # priv/tailscale (see NervesPhone.Tailscale). It's downloaded once per
  # version into _build/tailscale and checked against its SHA-256 (from
  # pkgs.tailscale.com/stable/<tarball>.sha256).
  @tailscale_version "1.104.1"
  @tailscale_sha256 "f60294374967f3dfd8cf57bbbd474d6cfce32d123e3a8ddeab82a87940daa806"

  defp add_tailscale(%Mix.Release{} = release) do
    if Mix.target() != :host do
      bin =
        Path.join(Mix.Project.build_path(), "../tailscale/#{@tailscale_version}") |> Path.expand()

      if not File.exists?(Path.join(bin, "tailscaled")), do: fetch_tailscale(bin)

      [priv] = Path.wildcard(Path.join(release.path, "lib/#{@app}-*/priv"))
      File.cp_r!(bin, Path.join(priv, "tailscale"))
    end

    release
  end

  defp fetch_tailscale(bin) do
    tarball = "tailscale_#{@tailscale_version}_arm64.tgz"
    Mix.shell().info("==> Fetching #{tarball}")

    archive =
      case Mix.Utils.read_path("https://pkgs.tailscale.com/stable/#{tarball}", timeout: 300_000) do
        {:ok, body} -> body
        {_kind, message} -> Mix.raise("Downloading #{tarball} failed: #{message}")
      end

    if Base.encode16(:crypto.hash(:sha256, archive), case: :lower) != @tailscale_sha256 do
      Mix.raise("#{tarball} doesn't match its pinned SHA-256")
    end

    dir = "tailscale_#{@tailscale_version}_arm64"
    files = for name <- ~w(tailscale tailscaled), do: ~c"#{dir}/#{name}"
    {:ok, extracted} = :erl_tar.extract({:binary, archive}, [:compressed, :memory, files: files])

    File.mkdir_p!(bin)

    for {path, contents} <- extracted do
      dest = Path.join(bin, Path.basename(to_string(path)))
      File.write!(dest, contents)
      File.chmod!(dest, 0o755)
    end
  end

  # Membrane's precompiled PortAudio arrives as a ~100 MB bundle of
  # libraries per platform. Bundlex keeps the downloads in its own priv, and
  # copies them next to the NIFs, which only need PortAudio and what it
  # links that the Nerves system doesn't have (libasound comes from the
  # system). Drop the download cache and everything else.
  @portaudio_libs ~w(libportaudio.so libjack.so libdb-5.3.so)

  defp trim_portaudio(%Mix.Release{} = release) do
    if Mix.target() != :host do
      release.path
      |> Path.join("lib/membrane_portaudio_plugin-*/priv/bundlex/nif/*portaudio*/*")
      |> Path.wildcard()
      |> Enum.reject(fn path ->
        name = Path.basename(path)
        Enum.any?(@portaudio_libs, &String.starts_with?(name, &1))
      end)
      |> Enum.each(&File.rm_rf!/1)

      release.path
      |> Path.join("lib/bundlex-*/priv/shared/precompiled")
      |> Path.wildcard()
      |> Enum.each(&File.rm_rf!/1)
    end

    release
  end
end
