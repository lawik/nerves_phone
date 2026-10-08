defmodule NervesPhone.Apps.Videos.State do
  @moduledoc """
  The Videos app's controller: the video files found under `/data`, and
  what's playing.

  Pages are `:library` and `:player`, which takes the whole screen. Its
  controls hide a few seconds into playing; a tap on the video shows them
  again. Playing a file starts a
  `NervesPhone.Video.Player` pipeline that reports back here, and keeps
  the screen on while it plays.

  Stopping goes in two steps. The player page goes away first, so the UI
  drops the video element and Emerge lets go of the frame it shows; the
  pipeline stops a moment later.

  A new video only starts once the previous pipeline has gone: the sound
  card takes one stream at a time, so the new one couldn't open it while
  the old one still has it. If the old one takes too long, the new one
  starts anyway.
  """

  use Solve.Controller,
    events: [:opened, :rescan, :play, :toggle_pause, :stop, :show, :toggle_controls]

  alias NervesPhone.Video.{Library, Player}

  # Long enough for the UI to re-render without the video element.
  @stop_delay_ms 300
  # Each playback gets its own video target (see Player.start/3), from a
  # fixed set so atoms don't pile up. A target is long gone from the screen
  # by the time its name comes round again.
  @targets for n <- 0..63, do: :"video_#{n}"

  # A new video waits at most this long for the previous one to stop.
  @handover_timeout_ms 3_000

  # The player's controls hide this long after the last touch while playing.
  @controls_ms 4_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :scan)

    %{
      page: :library,
      folders: [],
      scanning: true,
      playback: nil,
      controls: true,
      controls_gen: 0,
      plays: 0,
      # Pipelines being stopped, by monitor.
      stopping: %{}
    }
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{
      page: state.page,
      folders: state.folders,
      scanning: state.scanning,
      controls: state.controls,
      playback: state.playback && Map.drop(state.playback, [:pipeline, :monitor])
    }
  end

  def opened(_payload, state) do
    send(self(), :scan)
    %{state | scanning: true}
  end

  def rescan(_payload, state), do: opened(nil, state)

  def show(:library, state), do: %{state | page: :library}

  def show(:player, %{playback: playback} = state) when playback != nil,
    do: %{state | page: :player}

  def show(_page, state), do: state

  def play(path, state) when is_binary(path) do
    state = stop_playback(state)
    target = Enum.at(@targets, rem(state.plays, length(@targets)))

    playback = %{
      path: path,
      name: Path.basename(path),
      target: target,
      status: :starting,
      position_ms: 0,
      pipeline: nil,
      monitor: nil
    }

    state = %{show_controls(state) | page: :player, plays: state.plays + 1, playback: playback}

    if state.stopping == %{} do
      start_pipeline(state)
    else
      Process.send_after(self(), {:handover_timeout, state.plays}, @handover_timeout_ms)
      state
    end
  end

  def toggle_pause(_payload, %{playback: %{pipeline: pipeline, status: status} = p} = state)
      when pipeline != nil do
    case status do
      :playing ->
        player().pause(pipeline)
        NervesPhone.Screen.keep_awake(false)
        show_controls(%{state | playback: %{p | status: :paused}})

      :paused ->
        player().resume(pipeline)
        NervesPhone.Screen.keep_awake(true)
        show_controls(%{state | playback: %{p | status: :playing}})

      _other ->
        state
    end
  end

  def toggle_pause(_payload, state), do: state

  def stop(_payload, state), do: %{stop_playback(state) | page: :library}

  def toggle_controls(_payload, state) do
    if state.controls, do: %{state | controls: false}, else: show_controls(state)
  end

  def handle_info(:scan, state) do
    controller = self()

    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
      send(controller, {:scanned, Library.scan()})
    end)

    state
  end

  def handle_info({:scanned, folders}, state), do: %{state | folders: folders, scanning: false}

  def handle_info({:video, message}, %{playback: %{} = playback} = state) do
    playback =
      case message do
        :playing -> %{playback | status: :playing}
        {:position, ms} -> %{playback | position_ms: ms}
        :ended -> ended(playback)
        {:error, reason} -> %{playback | status: {:error, reason}}
      end

    state = %{state | playback: playback}
    if message == :playing, do: show_controls(state), else: state
  end

  # A stopped pipeline has gone; start the video waiting for it.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stopping: stopping} = state)
      when is_map_key(stopping, ref) do
    state = %{state | stopping: Map.delete(stopping, ref)}
    if state.stopping == %{}, do: start_pipeline(state), else: state
  end

  def handle_info({:handover_timeout, plays}, %{plays: plays} = state),
    do: start_pipeline(state)

  def handle_info({:handover_timeout, _stale}, state), do: state

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{playback: %{monitor: ref} = p} = state) do
    NervesPhone.Screen.keep_awake(false)
    status = if p.status in [:ended, :stopped], do: p.status, else: {:error, {:crashed, reason}}
    %{state | playback: %{p | pipeline: nil, monitor: nil, status: status}}
  end

  # Hide the controls if nothing has shown them since, and it's playing.
  def handle_info({:hide_controls, gen}, %{controls_gen: gen} = state) do
    case state.playback do
      %{status: :playing} -> %{state | controls: false}
      _ -> state
    end
  end

  def handle_info({:hide_controls, _stale}, state), do: state

  def handle_info({:stop_pipeline, pipeline}, state) do
    player().stop(pipeline)
    state
  end

  def handle_info(_message, state), do: state

  defp show_controls(state) do
    gen = state.controls_gen + 1
    Process.send_after(self(), {:hide_controls, gen}, @controls_ms)
    %{state | controls: true, controls_gen: gen}
  end

  # `config :nerves_phone, :video_player` swaps the player (for tests).
  defp player, do: Application.get_env(:nerves_phone, :video_player, Player)

  defp ended(playback) do
    NervesPhone.Screen.keep_awake(false)
    %{playback | status: :ended}
  end

  # Starts the pipeline for a playback waiting to start (once).
  defp start_pipeline(%{playback: %{status: :starting, pipeline: nil} = p} = state) do
    case player().start(p.path, self(), p.target) do
      {:ok, pipeline} ->
        NervesPhone.Screen.keep_awake(true)

        %{state | playback: %{p | pipeline: pipeline, monitor: Process.monitor(pipeline)}}

      {:error, reason} ->
        %{state | playback: %{p | status: {:error, reason}}}
    end
  end

  defp start_pipeline(state), do: state

  # Takes the player off screen now and stops the pipeline shortly after
  # (see the moduledoc), watching it until it's gone.
  defp stop_playback(%{playback: %{pipeline: pipeline, monitor: monitor}} = state)
       when pipeline != nil do
    NervesPhone.Screen.keep_awake(false)
    Process.send_after(self(), {:stop_pipeline, pipeline}, @stop_delay_ms)
    %{state | playback: nil, page: :library, stopping: Map.put(state.stopping, monitor, pipeline)}
  end

  defp stop_playback(state), do: %{state | playback: nil}
end
