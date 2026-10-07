defmodule Mix.Tasks.Compile.Librespot do
  @shortdoc "Builds librespot and the spotify-meta helper for the current target"
  @moduledoc """
  Builds the Spotify backend's two native programs with cargo, into
  `_build/librespot/<version>-<target>/bin/`:

    * `librespot`, the Spotify Connect receiver, once per target and
      librespot version. It's built with only the pipe audio backend (PCM
      goes to a FIFO that the Membrane pipeline reads), rustls for TLS and
      libmdns for Spotify Connect discovery.
    * `spotify-meta` from `native/spotify_meta`, which lists playlists the
      Web API won't. Rebuilt when its sources change.

  For a Nerves target it cross-compiles with the system's toolchain and
  sysroot.
  """
  use Mix.Task.Compiler

  @version "0.8.0"
  @features "rustls-tls-webpki-roots,with-libmdns"

  @meta_src Path.expand("native/spotify_meta", __DIR__)

  @impl Mix.Task.Compiler
  def run(_args) do
    built_librespot? = if File.exists?(path()), do: false, else: build()
    built_meta? = if meta_stale?(), do: build_meta(), else: false
    if built_librespot? or built_meta?, do: {:ok, []}, else: {:noop, []}
  end

  @doc "Where librespot for the current target ends up."
  def path, do: Path.join([root(), "bin", "librespot"])

  @doc "Where spotify-meta for the current target ends up."
  def meta_path, do: Path.join([root(), "bin", "spotify-meta"])

  defp meta_stale? do
    case File.stat(meta_path(), time: :posix) do
      {:ok, %{mtime: built}} ->
        sources =
          ["Cargo.toml", "Cargo.lock", "src/**/*.rs"]
          |> Enum.flat_map(&Path.wildcard(Path.join(@meta_src, &1)))
        Enum.any?(sources, &(File.stat!(&1, time: :posix).mtime > built))

      _ ->
        true
    end
  end

  defp build_meta do
    Mix.shell().info("==> Building spotify-meta for #{Mix.target()}")

    args =
      ["install", "--path", @meta_src, "--locked", "--force", "--root", root()] ++ target_args()

    case System.cmd("cargo", args, env: cargo_env(), stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> true
      {_, status} -> Mix.raise("Building spotify-meta failed (cargo exited with #{status})")
    end
  end

  defp root do
    Path.join([Mix.Project.build_path(), "..", "librespot", "#{@version}-#{Mix.target()}"])
    |> Path.expand()
  end

  defp build do
    Mix.shell().info("==> Building librespot #{@version} for #{Mix.target()}")

    args =
      ~w(install librespot --version #{@version} --locked --force --no-default-features) ++
        ["--features", @features, "--root", root()] ++ target_args()

    case System.cmd("cargo", args, env: cargo_env(), stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> true
      {_, status} -> Mix.raise("Building librespot failed (cargo exited with #{status})")
    end
  end

  defp target_args do
    case rust_target() do
      nil -> []
      triple -> ["--target", triple]
    end
  end

  # aarch64-nerves-linux-gnu -> aarch64-unknown-linux-gnu
  defp rust_target do
    case System.get_env("CROSSCOMPILE") do
      nil -> nil
      prefix -> prefix |> Path.basename() |> String.replace("-nerves-", "-unknown-")
    end
  end

  defp cargo_env do
    # Host-side build scripts need the host's ar, not the cross-ar wrapper.
    path =
      System.get_env("PATH", "")
      |> String.split(":")
      |> Enum.reject(&String.ends_with?(&1, "scripts/cross-ar"))
      |> Enum.join(":")

    base = [{"CARGO_PROFILE_RELEASE_STRIP", "true"}, {"PATH", path}]

    case {rust_target(), System.get_env("CROSSCOMPILE"), System.get_env("NERVES_SDK_SYSROOT")} do
      {nil, _, _} ->
        base

      {triple, prefix, sysroot} ->
        key = triple |> String.upcase() |> String.replace("-", "_")
        cc_key = String.replace(triple, "-", "_")

        # Nerves exports CC/CFLAGS for the target. Clear them so build
        # scripts compiled for the host use the host compiler, and give the
        # target compiler through cargo's per-target variables instead.
        base ++
          Enum.map(~w(CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS AR), &{&1, nil}) ++
          [
            {"CC_#{cc_key}", prefix <> "-gcc"},
            {"AR_#{cc_key}", prefix <> "-ar"},
            {"CFLAGS_#{cc_key}", "--sysroot=#{sysroot}"},
            {"CARGO_TARGET_#{key}_LINKER", prefix <> "-gcc"},
            {"CARGO_TARGET_#{key}_RUSTFLAGS", "-C link-arg=--sysroot=#{sysroot}"}
          ]
    end
  end
end

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
      compilers: Mix.compilers() ++ [:librespot],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
    [preferred_targets: [run: :host, test: :host, "spotify.login": :host]]
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

      # Audio: librespot's PCM runs through a Membrane pipeline to PortAudio.
      {:membrane_core, "~> 1.2"},
      {:membrane_raw_audio_format, "~> 0.12.0"},
      {:membrane_portaudio_plugin, "~> 0.19.6"},

      # Spotify Web API
      {:req, "~> 0.7"},

      # Runs librespot and cleans it up if the BEAM goes away.
      {:muontrap, "~> 1.5"},

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
        :assemble,
        &drop_foreign_nifs/1,
        &trim_portaudio/1,
        &add_librespot/1
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

  # librespot and spotify-meta are built outside the app's priv (they're per
  # target), so copy the target's binaries into the release.
  defp add_librespot(%Mix.Release{} = release) do
    if Mix.target() != :host do
      bin = Path.join([release.path, "lib", "#{@app}-#{@version}", "priv", "bin"])
      File.mkdir_p!(bin)

      for src <- [Mix.Tasks.Compile.Librespot.path(), Mix.Tasks.Compile.Librespot.meta_path()] do
        dest = Path.join(bin, Path.basename(src))
        File.cp!(src, dest)
        File.chmod!(dest, 0o755)
      end
    end

    release
  end
end
