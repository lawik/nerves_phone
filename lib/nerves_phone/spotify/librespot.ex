defmodule NervesPhone.Spotify.Librespot do
  @moduledoc """
  Runs librespot, the Spotify Connect receiver that does the actual
  streaming and decoding.

  librespot writes 44.1 kHz stereo S16 PCM into a FIFO, which
  `NervesPhone.Audio.Pipeline` reads and plays (see `NervesPhone.Spotify.audio_fifo/0`). It runs with autoplay off,
  so Spotify never appends recommendations when a playlist runs out, and
  librespot has no smart shuffle, so shuffle is always plain shuffle.

  Signing in: `mix spotify.login` logs librespot in with its own OAuth
  (Spotify Connect refuses credentials made from another app's token) and
  the credentials are baked into the firmware. They're written to
  librespot's cache in `state_dir/librespot` whenever a new login comes
  with the firmware. Without them, librespot still shows up over Spotify
  Connect discovery: picking "Nerves Phone" once in a Spotify app on the
  same network signs it in.
  """

  use GenServer
  require Logger

  alias NervesPhone.Spotify.Auth

  @min_restart_ms 5_000
  @max_restart_ms 120_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The FIFO librespot writes PCM to."
  def fifo, do: Path.join(System.tmp_dir!(), "nerves_phone_librespot.pcm")

  @impl GenServer
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :ok = ensure_fifo(fifo())
    seed_credentials()
    send(self(), :start)
    {:ok, %{daemon: nil, restart_ms: @min_restart_ms}}
  end

  @impl GenServer
  def handle_info(:start, state) do
    path = executable()

    if File.exists?(path) do
      Logger.info("[librespot] starting")

      {:ok, daemon} =
        MuonTrap.Daemon.start_link(path, args(),
          stderr_to_stdout: true,
          log_output: :info,
          log_prefix: "[librespot] "
        )

      {:noreply, %{state | daemon: daemon}}
    else
      Logger.error("[librespot] not found at #{path}")
      {:noreply, state}
    end
  end

  # librespot exited (no network yet, refused credentials): try again, less
  # often each time.
  def handle_info({:EXIT, daemon, reason}, %{daemon: daemon} = state) do
    Logger.warning(
      "[librespot] exited (#{inspect(reason)}), restarting in #{state.restart_ms} ms"
    )

    Process.send_after(self(), :start, state.restart_ms)
    {:noreply, %{state | daemon: nil, restart_ms: min(state.restart_ms * 2, @max_restart_ms)}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp args do
    ~w(--backend pipe --format S16 --bitrate 320 --autoplay off --initial-volume 100) ++
      ~w(--enable-volume-normalisation --device-type smartphone --disable-audio-cache) ++
      ["--name", Auth.config()[:device_name] || "Nerves Phone"] ++
      ["--device", fifo(), "--cache", cache_dir()]
  end

  @doc "librespot's cache, holding its reusable credentials."
  def cache_dir, do: Path.join(Auth.state_dir(), "librespot")

  # Writes the baked-in credentials to librespot's cache when they're new,
  # replacing whatever an earlier login left there.
  defp seed_credentials do
    case Auth.config()[:librespot_credentials] do
      creds when is_map(creds) ->
        json = JSON.encode!(creds)
        marker = Path.join(cache_dir(), ".seed")
        seed = :crypto.hash(:sha256, json) |> Base.encode16()
        File.mkdir_p!(cache_dir())

        if File.read(marker) != {:ok, seed} do
          File.write!(Path.join(cache_dir(), "credentials.json"), json)
          File.chmod!(Path.join(cache_dir(), "credentials.json"), 0o600)
          File.write!(marker, seed)
        end

      _ ->
        :ok
    end
  end

  defp executable do
    Application.get_env(:nerves_phone, :librespot) ||
      Application.app_dir(:nerves_phone, "priv/bin/librespot")
  end

  # mkfifo on the host; BusyBox has `mknod PATH p` on the phone.
  defp ensure_fifo(path) do
    case File.stat(path) do
      {:ok, %{type: :other}} ->
        :ok

      other ->
        if match?({:ok, _}, other), do: File.rm!(path)

        {cmd, args} =
          cond do
            exe = System.find_executable("mkfifo") -> {exe, [path]}
            exe = System.find_executable("mknod") -> {exe, [path, "p"]}
            true -> {"busybox", ["mknod", path, "p"]}
          end

        {_, 0} = System.cmd(cmd, args, stderr_to_stdout: true)
        :ok
    end
  end
end
