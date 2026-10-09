defmodule NervesPhone.Flashcards.Sound do
  @moduledoc """
  Plays the sounds on flash cards (`[sound:...]`, mostly MP3), one after
  another, and stops them when the card changes.

  On the phone they're turned into WAV with `ffmpeg` the first time (kept
  next to the deck's media) and played with `aplay`, through ALSA's
  software volume like everything else (`NervesPhone.Audio.Volume`). On
  the host, macOS's `afplay` plays them as they are. `config :nerves_phone,
  :flashcards, sound: nil` turns sound off (as in tests).
  """

  use GenServer

  require Logger

  @default if Mix.target() == :host, do: :afplay, else: :aplay

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Plays files one after the other, stopping what's playing."
  @spec play([Path.t()]) :: :ok
  def play(paths), do: GenServer.cast(__MODULE__, {:play, paths})

  @doc "Stops what's playing."
  @spec stop() :: :ok
  def stop, do: GenServer.cast(__MODULE__, :stop)

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_cast({:play, paths}, task) do
    stop_task(task)

    case player() do
      nil ->
        {:noreply, nil}

      player ->
        {:ok, task} =
          Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
            Enum.each(paths, &play_file(player, &1))
          end)

        {:noreply, task}
    end
  end

  def handle_cast(:stop, task) do
    stop_task(task)
    {:noreply, nil}
  end

  # MuonTrap kills the player when the task goes.
  defp stop_task(nil), do: :ok
  defp stop_task(task), do: Process.exit(task, :kill)

  defp player,
    do: Application.get_env(:nerves_phone, :flashcards, []) |> Keyword.get(:sound, @default)

  defp play_file(:afplay, path), do: run("afplay", [path])

  defp play_file(:aplay, path) do
    with {:ok, wav} <- wav(path) do
      # Volume's control appears once the sound card's open.
      spawn(fn ->
        Process.sleep(200)
        NervesPhone.Audio.Volume.reapply()
      end)

      run("aplay", ["-q", wav])
    end
  end

  defp wav(path) do
    if String.downcase(Path.extname(path)) == ".wav" do
      {:ok, path}
    else
      wav = path <> ".play.wav"
      tmp = wav <> ".tmp"

      cond do
        File.exists?(wav) ->
          {:ok, wav}

        run("ffmpeg", ~w(-y -loglevel error -i) ++ [path] ++ ~w(-ac 2 -ar 48000 -f wav) ++ [tmp]) ==
            :ok ->
          File.rename(tmp, wav)
          {:ok, wav}

        true ->
          File.rm(tmp)
          :error
      end
    end
  end

  defp run(command, args) do
    case MuonTrap.cmd(command, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, status} ->
        Logger.warning("#{command} exited with #{status}: #{String.trim(output)}")
        :error
    end
  rescue
    error ->
      Logger.warning("Couldn't run #{command}: #{Exception.message(error)}")
      :error
  end
end
