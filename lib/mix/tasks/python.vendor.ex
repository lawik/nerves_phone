defmodule Mix.Tasks.Python.Vendor do
  @shortdoc "Downloads Python and the Python packages the phone uses into priv"
  @moduledoc """
  Downloads the Python that `NervesPhone.Python` embeds, and the packages
  `NervesPhone.SvtPlay` and `NervesPhone.YtDlp` use, into
  `priv/python/<target>`, for the current `MIX_TARGET`:

      mix python.vendor
      MIX_TARGET=fp3 mix python.vendor

  Building a release runs it when the target's Python is missing or was
  vendored from different pins (see `vendor_python` in mix.exs), so it's
  only needed by hand on the host.

  The Nerves system has ffmpeg but no Python, so a standalone CPython
  (from python-build-standalone) ships in the firmware, and Pythonx
  embeds it. svtplay-dl needs cryptography and PyYAML, which are native,
  so each target gets its own interpreter and wheels. The release keeps
  only the target's (see `drop_foreign_python` in mix.exs).

  Everything is pinned and checked against its SHA-256. To update a
  wheel, change its version and hash below (both are on the package's
  PyPI page, under "Download files"). The wheels must match the Python
  version (cp313, or abi3).

    * CPython 3.13, without its tests, Tk and other parts nothing uses
    * `svtplay-dl`, which is only on PyPI as source. It's pure Python,
      so its package directory is copied out of the source archive.
    * `requests` and its dependencies (`urllib3`, `idna`, `certifi`,
      `charset-normalizer`), plus `PySocks` for proxies
    * `cryptography` (with `cffi` and `pycparser`), for encrypted HLS
    * `PyYAML`, for svtplay-dl's settings files
    * `yt-dlp`
    * `yt-dlp-ejs`, the JavaScript yt-dlp runs to solve YouTube's
      challenges. It needs a JS runtime (deno, node, bun or QuickJS) on the
      PATH; without one, YouTube only offers some formats.
  """

  use Mix.Task

  @pypi "https://files.pythonhosted.org/packages"
  @pbs "https://github.com/astral-sh/python-build-standalone/releases/download/20261003"

  @svtplay_dl {"svtplay_dl-4.199.tar.gz",
               "#{@pypi}/35/ed/7c28095881f133289284ca75c53ee64cb2e71f900e44b7da7acdfeba9f5b/svtplay_dl-4.199.tar.gz",
               "ef7213ea504b339fec42cf1e6e99a048d1f75654d80325d45f418a971906c4ea"}

  @pure_wheels [
    {"requests-2.34.2-py3-none-any.whl",
     "#{@pypi}/a0/f4/c67b0b3f1b9245e8d266f0f112c500d50e5b4e83cb6f3b71b6528104182a/requests-2.34.2-py3-none-any.whl",
     "2a0d60c172f83ac6ab31e4554906c0f3b3588d37b5cb939b1c061f4907e278e0"},
    {"urllib3-2.8.0-py3-none-any.whl",
     "#{@pypi}/92/9d/c4e665119135114480843e7ab388fa94d8480650450e6f8e26b70d323a4c/urllib3-2.8.0-py3-none-any.whl",
     "0cf3cae568d36aa9576b28dfb35f11328f1cb974ca7647d9475ebb86c75ac6e3"},
    {"idna-3.20-py3-none-any.whl",
     "#{@pypi}/58/a2/bb081bab032533a855d44de1d56f8e8426114ff1ba5d1f07a438a0a654f8/idna-3.20-py3-none-any.whl",
     "ab7ae7122974553370f0bdb919e1a960b2cd1bc1ef0276416d896db81c14582c"},
    {"certifi-2026.7.22-py3-none-any.whl",
     "#{@pypi}/0b/a7/71ac2cff56fec219ed242bb11b8efb69fcc4bec75db06fb7bfe35de520e6/certifi-2026.7.22-py3-none-any.whl",
     "62f22742b58a1a33014a2b6b706588a8d7e2a88ae7bd1a6ebe8c992928483775"},
    {"charset_normalizer-3.5.2-py3-none-any.whl",
     "#{@pypi}/fc/ad/d07d7862a62ffa6d79d68074d14823243dd235a77c45262acbf6adeb28bf/charset_normalizer-3.5.2-py3-none-any.whl",
     "b6b751274acb69d77b3323d6b7dbaa3c7fdfc1eb829b7eb61d262f32e1af9685"},
    {"PySocks-1.7.1-py3-none-any.whl",
     "#{@pypi}/8d/59/b4572118e098ac8e46e399a1dd0f2d85403ce8bbaad9ec79373ed6badaf9/PySocks-1.7.1-py3-none-any.whl",
     "2725bd0a9925919b9b51739eea5f9e2bae91e83288108a9ad338b2e3a4435ee5"},
    {"pycparser-3.1-py3-none-any.whl",
     "#{@pypi}/99/ce/b3ae9ee0324d991c860187be2a6ee436d27a3d02397eaddbb101ec901f3d/pycparser-3.1-py3-none-any.whl",
     "f09d358c840bd147b79e55f2bc494f18ea869dc897f5852a8f5766b74f787882"},
    {"yt_dlp-2026.8.19-py3-none-any.whl",
     "#{@pypi}/69/b2/8cd1613f56eed7ceb64fbd4df3f1c01246bfb098e6f398228bafda22b80b/yt_dlp-2026.8.19-py3-none-any.whl",
     "1d57897e94c6665a0a6f9bc54b34e584284e32c034ffab3a7df25d8f7b24eedf"},
    {"yt_dlp_ejs-0.8.0-py3-none-any.whl",
     "#{@pypi}/e3/bd/520769863744b669440a924271a6159ddd82ad5ae26b4ac4d4b69e9f8d44/yt_dlp_ejs-0.8.0-py3-none-any.whl",
     "79300e5fca7f937a1eeede11f0456862c1b41107ce1d726871e0207424f4bdb4"}
  ]

  # The phone (aarch64 glibc Linux) and an Apple Silicon Mac for the host.
  @platforms %{
    "aarch64-linux" => %{
      python:
        {"cpython-3.13.16+20261003-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz",
         "#{@pbs}/cpython-3.13.16%2B20261003-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz",
         "6e9641400f8debd9b7924b27b5ff0662c372852382e291a76c450c7b67414cf6"},
      wheels: [
        {"cryptography-50.0.2-cp311-abi3-manylinux_2_28_aarch64.whl",
         "#{@pypi}/38/6b/61a3f8d8c5e1e49a6cddccafc4015cc1c0021360ab0acb4080e7a423644a/cryptography-50.0.2-cp311-abi3-manylinux_2_28_aarch64.whl",
         "f9f6143a8c75945eb960d9eb98905a441394abfa24afaae239d514ffb2586480"},
        {"cffi-2.1.1-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.whl",
         "#{@pypi}/37/6f/3b5ce4c3b2192d250f04908f2bfd91ef34552ec8f7716a5d4abdb8d67bb2/cffi-2.1.1-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.whl",
         "f16c709686a78c727bbbf059f92b0bf41c6fc60deec706d2dc19f529175a6125"},
        {"pyyaml-6.0.3-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl",
         "#{@pypi}/50/31/b20f376d3f810b9b2371e72ef5adb33879b25edb7a6d072cb7ca0c486398/pyyaml-6.0.3-cp313-cp313-manylinux2014_aarch64.manylinux_2_17_aarch64.manylinux_2_28_aarch64.whl",
         "ee2922902c45ae8ccada2c5b501ab86c36525b883eff4255313a253a3160861c"}
      ]
    },
    "aarch64-darwin" => %{
      python:
        {"cpython-3.13.16+20261003-aarch64-apple-darwin-install_only_stripped.tar.gz",
         "#{@pbs}/cpython-3.13.16%2B20261003-aarch64-apple-darwin-install_only_stripped.tar.gz",
         "9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147"},
      wheels: [
        {"cryptography-50.0.2-cp311-abi3-macosx_11_0_arm64.whl",
         "#{@pypi}/e5/56/d194340cc4a57535e82e1bee9e89667ac4b7c13b5d3f59686deae3094dd5/cryptography-50.0.2-cp311-abi3-macosx_11_0_arm64.whl",
         "fa8f5efb344d6908a1ce62f4a24e2e5780f825d6f53f5f50ec5ffacac72936cb"},
        {"cffi-2.1.1-cp313-cp313-macosx_11_0_arm64.whl",
         "#{@pypi}/55/41/4c7042f317b9217502988f0873af87e16ad606dc20f84e546e3e6ce9764c/cffi-2.1.1-cp313-cp313-macosx_11_0_arm64.whl",
         "19ee6127ee34de7d83ce3d371ebc5ed91addbdcc39f9ab15ce4eb35a4e534971"},
        {"pyyaml-6.0.3-cp313-cp313-macosx_11_0_arm64.whl",
         "#{@pypi}/b1/16/95309993f1d3748cd644e02e38b75d50cbc0d9561d21f390a76242ce073f/pyyaml-6.0.3-cp313-cp313-macosx_11_0_arm64.whl",
         "2283a07e2c21a2aa78d9c4442724ec1eb15f5e42a723b99cb3d822d48f5f7ad1"}
      ]
    }
  }

  # Parts of the standard library that nothing here imports, by size.
  @stdlib_unused ~w(test idlelib tkinter turtledemo ensurepip lib2to3)

  @doc "Where the current target's Python and packages go."
  def dest, do: Path.expand("priv/python/#{Mix.target()}")

  @doc """
  Whether the current target's Python was vendored from the pins in this
  version of the task.
  """
  def up_to_date? do
    File.read(stamp_path()) == {:ok, stamp()}
  end

  defp stamp_path, do: Path.join(dest(), ".vendored")

  defp stamp do
    pins = {@svtplay_dl, @pure_wheels, Map.fetch!(@platforms, platform(Mix.target()))}
    :crypto.hash(:sha256, :erlang.term_to_binary(pins)) |> Base.encode16(case: :lower)
  end

  @impl Mix.Task
  def run(_args) do
    platform = platform(Mix.target())
    %{python: python, wheels: wheels} = Map.fetch!(@platforms, platform)

    dest = dest()
    File.rm_rf!(dest)
    File.mkdir_p!(dest)

    # The archive holds a single python/ directory. Its headers and
    # terminfo aren't needed, and :erl_tar won't extract terminfo's
    # symlinks anyway. Neither is bin/: Pythonx loads libpython, and
    # bin/python3 would be a second, 20 MB copy of it.
    {name, _url, _sha256} = python
    Mix.shell().info("==> Fetching #{name}")
    archive = {:binary, fetch!(python)}
    {:ok, names} = :erl_tar.table(archive, [:compressed])

    keep =
      Enum.reject(names, fn name ->
        match?(
          ["python", dir | _] when dir in ["bin", "include", "share"],
          Path.split(to_string(name))
        )
      end)

    :ok = :erl_tar.extract(archive, [:compressed, files: keep, cwd: String.to_charlist(dest)])

    trim_stdlib(Path.join(dest, "python"))

    site_packages = Path.join(dest, "site-packages")
    File.mkdir_p!(site_packages)

    for {name, _url, _sha256} = wheel <- @pure_wheels ++ wheels do
      Mix.shell().info("==> Fetching #{name}")
      # A wheel is a zip of the files as they'd be installed.
      {:ok, _files} = :zip.extract(fetch!(wheel), cwd: String.to_charlist(site_packages))
    end

    {name, _url, _sha256} = @svtplay_dl
    Mix.shell().info("==> Fetching #{name}")
    vendor_svtplay_dl(fetch!(@svtplay_dl), site_packages)

    File.write!(stamp_path(), stamp())
    Mix.shell().info("Vendored into #{Path.relative_to_cwd(dest)}")
  end

  defp platform(:host) do
    case :erlang.system_info(:system_architecture) |> to_string() do
      "aarch64-apple-darwin" <> _ ->
        "aarch64-darwin"

      arch ->
        Mix.raise("""
        There's no Python pinned for this host (#{arch}). Add one for it to
        @platforms in #{Path.relative_to_cwd(__ENV__.file)}.
        """)
    end
  end

  defp platform(:fp3), do: "aarch64-linux"

  defp trim_stdlib(python_dir) do
    [stdlib] = Path.wildcard(Path.join(python_dir, "lib/python3.*"))
    Enum.each(@stdlib_unused, &File.rm_rf!(Path.join(stdlib, &1)))

    # Tk's libraries and scripts, which only tkinter loads.
    python_dir
    |> Path.join("lib/{tcl,tk,itcl,thread,libtcl,libtk}*")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf!/1)

    stdlib |> Path.join("lib-dynload/_tkinter*") |> Path.wildcard() |> Enum.each(&File.rm!/1)
  end

  # The source archive's lib/svtplay_dl is the package as it's installed.
  defp vendor_svtplay_dl(archive, site_packages) do
    {:ok, files} = :erl_tar.extract({:binary, archive}, [:compressed, :memory])

    for {path, contents} <- files,
        [_root, "lib", "svtplay_dl" | rest] <- [Path.split(to_string(path))],
        rest != [] do
      dest = Path.join([site_packages, "svtplay_dl" | rest])
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, contents)
    end
  end

  defp fetch!({name, url, sha256}) do
    body =
      case Mix.Utils.read_path(url) do
        {:ok, body} -> body
        {_kind, message} -> Mix.raise("Downloading #{url} failed: #{message}")
      end

    if Base.encode16(:crypto.hash(:sha256, body), case: :lower) != sha256 do
      Mix.raise("#{name} doesn't match its pinned SHA-256")
    end

    body
  end
end
