defmodule NervesPhone.Audio.Volume do
  @moduledoc """
  Volume, set by the phone's buttons.

  On the phone it's ALSA's software volume control "Master", which
  `rootfs_overlay/etc/asound.conf` puts in front of the sound card, so
  alsa-lib applies the gain (no per-sample work in Elixir). The level is
  set with `amixer` from this process, so a button press never waits on it,
  and only the latest level is applied when presses come fast. The control
  only exists once the device has been opened, so applying retries until it
  works. On the host (no `volume_control` set) the level is only kept.

  The current level lives in an `:atomics` counter for cheap reads and is
  saved to `state_dir/volume` so it outlasts reboots. Levels go from 0 to
  #{16}; the control is linear in dB, from -60 dB (silent enough) to 0 dB.
  """

  use GenServer

  @steps 16
  @default 10
  @retry_ms 2_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The number of steps above silence."
  def steps, do: @steps

  @doc "The current level, 0..steps."
  def level, do: :atomics.get(ref(), 1)

  @doc "Sets the level (clamped), saves it and applies it. Returns the new level."
  def set(level) do
    level = level |> max(0) |> min(@steps)
    :atomics.put(ref(), 1, level)
    GenServer.cast(__MODULE__, :apply)
    level
  end

  def up, do: set(level() + 1)
  def down, do: set(level() - 1)

  @impl GenServer
  def init(_opts) do
    send(self(), :apply)
    {:ok, %{applied: nil}}
  end

  @impl GenServer
  def handle_cast(:apply, state), do: handle_info(:apply, state)

  @impl GenServer
  def handle_info(:apply, state) do
    level = level()

    if level == state.applied do
      {:noreply, state}
    else
      save(level)

      case apply_level(level) do
        :ok ->
          {:noreply, %{state | applied: level}}

        {:error, _reason} ->
          Process.send_after(self(), :apply, @retry_ms)
          {:noreply, state}
      end
    end
  end

  # `config :nerves_phone, volume_control: :alsa` on the phone.
  defp apply_level(level) do
    case Application.get_env(:nerves_phone, :volume_control) do
      :alsa -> set_alsa(level)
      _ -> :ok
    end
  end

  defp set_alsa(level) do
    raw = round(255 * level / @steps)
    args = ["-q", "-c", "0", "cset", "name=Master", "#{raw},#{raw}"]

    case System.cmd("amixer", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> {:error, {status, output}}
    end
  rescue
    e -> {:error, e}
  end

  defp ref do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        ref = :atomics.new(1, signed: false)
        :atomics.put(ref, 1, saved_level())
        :persistent_term.put(__MODULE__, ref)
        ref

      ref ->
        ref
    end
  end

  defp save(level) do
    File.mkdir_p(NervesPhone.Music.state_dir())
    File.write(path(), Integer.to_string(level))
  end

  defp saved_level do
    with {:ok, text} <- File.read(path()),
         {level, _} <- Integer.parse(String.trim(text)) do
      level |> max(0) |> min(@steps)
    else
      _ -> @default
    end
  end

  defp path, do: Path.join(NervesPhone.Music.state_dir(), "volume")
end
