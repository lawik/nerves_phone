defmodule NervesPhone.Apps.Videos.State do
  @moduledoc """
  The Videos app's controller: what's on offer (`NervesPhone.Kids`), and
  what's playing.

  Pages are `:offers` and `:player`, which takes the whole screen. Its
  controls hide a few seconds into playing; a tap on the video shows them
  again. Only offered videos play. Playing one starts a
  `NervesPhone.Video.Player` pipeline that reports back here, and keeps
  the screen on while it plays.

  Each play is an entry in `NervesPhone.Kids.History`, with the time it's
  actually played: the position moving on while it plays, not counting
  pauses or seeks. That's written as it goes and when it stops. When the
  video ends or is stopped, it's back to the offers, brought up to date.

  Stopping goes in two steps. The player page goes away first, so the UI
  drops the video element and Emerge lets go of the frame it shows; the
  pipeline stops a moment later.

  MP4 and QuickTime files are indexed first (`NervesPhone.Video.MP4`, cached
  on disk), which gives their duration and lets `:seek` play from any
  point. Seeking restarts the pipeline at the new time, on the same video
  target, so the current frame stays up meanwhile; while the scrubber is
  being dragged, the time shown follows it and the seek waits for a pause.

  A new video only starts once the previous pipeline has gone: the sound
  card takes one stream at a time, so the new one couldn't open it while
  the old one still has it. If the old one takes too long, the new one
  starts anyway.
  """

  use Solve.Controller,
    events: [:opened, :play, :toggle_pause, :stop, :toggle_controls, :seek]

  alias NervesPhone.Kids
  alias NervesPhone.Kids.History
  alias NervesPhone.Video.{MP4, Player}

  # Long enough for the UI to re-render without the video element.
  @stop_delay_ms 300
  # Each playback gets its own video target (see Player.start/3), from a
  # fixed set so atoms don't pile up. A target is long gone from the screen
  # by the time its name comes round again.
  @targets for n <- 0..63, do: :"video_#{n}"

  # A seek waits for the scrubber to stop moving this long.
  @seek_settle_ms 250

  # A new video waits at most this long for the previous one to stop.
  @handover_timeout_ms 3_000

  # The player's controls hide this long after the last touch while playing.
  @controls_ms 4_000

  # The time played is written to the history this often while playing.
  @save_every_s 30
  # Position steps longer than this are jumps (a seek), not play.
  @max_step_ms 2_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :load)

    %{
      page: :offers,
      offers: [],
      showing: "entertainment",
      loading: true,
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
      offers: state.offers,
      showing: state.showing,
      loading: state.loading,
      controls: state.controls,
      playback:
        state.playback &&
          Map.drop(state.playback, [:pipeline, :monitor, :index, :entry, :last_pos, :saved_s])
    }
  end

  def opened(_payload, %{playback: nil} = state) do
    send(self(), :load)
    %{state | loading: true}
  end

  def opened(_payload, state), do: state

  def play(path, state) when is_binary(path) do
    case Enum.find(state.offers, &(&1.path == path)) do
      nil -> state
      video -> play_video(video, stop_playback(state))
    end
  end

  defp play_video(video, state) do
    path = video.path
    target = Enum.at(@targets, rem(state.plays, length(@targets)))

    plays = state.plays + 1
    indexed? = String.downcase(Path.extname(path)) in ~w(.mp4 .m4v .mov)

    playback = %{
      path: path,
      name: video.title,
      entry: History.start(video),
      watched_ms: 0,
      saved_s: 0,
      last_pos: nil,
      target: target,
      status: :starting,
      position_ms: 0,
      duration_ms: nil,
      start_ms: 0,
      seek_gen: 0,
      seeking: false,
      # :pending while the file is being indexed; nil for raw H.264.
      index: if(indexed?, do: :pending, else: nil),
      pipeline: nil,
      monitor: nil
    }

    if indexed? do
      controller = self()

      Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
        send(controller, {:indexed, plays, MP4.index(path)})
      end)
    end

    state = %{show_controls(state) | page: :player, plays: plays, playback: playback}
    wait_for_handover(state) |> maybe_start()
  end

  # Dragging the scrubber: show the time now, seek once it settles.
  def seek(ms, %{playback: %{index: %{} = index} = p} = state) when is_number(ms) do
    ms = ms |> round() |> max(0) |> min(div(index.duration_ns, 1_000_000))
    gen = p.seek_gen + 1
    Process.send_after(self(), {:seek_now, gen}, @seek_settle_ms)

    show_controls(%{
      state
      | playback: %{
          p
          | position_ms: ms,
            seek_gen: gen,
            start_ms: ms,
            seeking: true,
            last_pos: nil
        }
    })
  end

  def seek(_ms, state), do: state

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

  def stop(_payload, state), do: state |> stop_playback() |> show_offers()

  def toggle_controls(_payload, state) do
    if state.controls, do: %{state | controls: false}, else: show_controls(state)
  end

  def handle_info(:load, state) do
    controller = self()

    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
      send(controller, {:offers, Kids.offers()})
    end)

    state
  end

  def handle_info({:offers, %{showing: showing, videos: videos}}, state),
    do: %{state | offers: videos, showing: showing, loading: false}

  # Only the current pipeline's news counts.
  def handle_info(
        {:video, pipeline, message},
        %{playback: %{pipeline: pipeline} = playback} = state
      )
      when pipeline != nil do
    case message do
      :ended ->
        state |> stop_playback() |> show_offers()

      _other ->
        playback =
          case message do
            :playing -> %{playback | status: :playing}
            {:position, _ms} when playback.seeking -> playback
            {:position, ms} -> playback |> count_played(ms) |> Map.put(:position_ms, ms)
            {:error, reason} -> %{playback | status: {:error, reason}}
          end

        state = %{state | playback: playback}
        if message == :playing, do: show_controls(state), else: state
    end
  end

  def handle_info({:indexed, plays, result}, %{plays: plays, playback: %{} = p} = state) do
    case result do
      {:ok, index} ->
        p = %{p | index: index, duration_ms: div(index.duration_ns, 1_000_000)}
        maybe_start(%{state | playback: p})

      {:error, reason} ->
        %{state | playback: %{p | index: nil, status: {:error, reason}}}
    end
  end

  def handle_info({:indexed, _stale, _result}, state), do: state

  # The scrubber has settled: play from there.
  def handle_info({:seek_now, gen}, %{playback: %{seek_gen: gen} = p} = state) do
    p = %{p | seeking: false}

    state =
      case p do
        %{pipeline: pipeline, monitor: monitor} when pipeline != nil ->
          Process.send_after(self(), {:stop_pipeline, pipeline}, 0)

          %{
            state
            | stopping: Map.put(state.stopping, monitor, pipeline),
              playback: %{p | status: :starting, pipeline: nil, monitor: nil}
          }

        _starting ->
          %{state | playback: %{p | status: :starting}}
      end

    state |> wait_for_handover() |> maybe_start()
  end

  def handle_info({:seek_now, _stale}, state), do: state

  # A stopped pipeline has gone; start the video waiting for it.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{stopping: stopping} = state)
      when is_map_key(stopping, ref) do
    maybe_start(%{state | stopping: Map.delete(stopping, ref)})
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

  # Adds the step from the last position to the time played, if it's a
  # step of playing rather than a jump, and writes it now and then.
  defp count_played(%{last_pos: last} = p, ms) do
    step = if last, do: ms - last, else: 0
    p = %{p | last_pos: ms}
    p = if step > 0 and step <= @max_step_ms, do: %{p | watched_ms: p.watched_ms + step}, else: p

    if div(p.watched_ms, 1000) - p.saved_s >= @save_every_s, do: save_played(p), else: p
  end

  defp save_played(p) do
    seconds = div(p.watched_ms, 1000)
    duration_s = p.duration_ms && div(p.duration_ms, 1000)
    if seconds != p.saved_s, do: History.watched(p.entry.id, seconds, duration_s)
    %{p | saved_s: seconds}
  end

  defp show_offers(state), do: opened(nil, %{state | page: :offers})

  defp wait_for_handover(%{stopping: stopping} = state) when stopping == %{}, do: state

  defp wait_for_handover(state) do
    Process.send_after(self(), {:handover_timeout, state.plays}, @handover_timeout_ms)
    state
  end

  # Starts the pipeline once the file is indexed and the last one has gone.
  defp maybe_start(%{stopping: stopping} = state) when stopping != %{}, do: state
  defp maybe_start(%{playback: %{index: :pending}} = state), do: state
  defp maybe_start(state), do: start_pipeline(state)

  # Starts the pipeline for a playback waiting to start (once).
  defp start_pipeline(%{playback: %{index: :pending}} = state), do: state

  defp start_pipeline(%{playback: %{status: :starting, pipeline: nil} = p} = state) do
    opts = [index: p.index, start_ms: p.start_ms]

    case player().start(p.path, self(), p.target, opts) do
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
    save_played(state.playback)
    Process.send_after(self(), {:stop_pipeline, pipeline}, @stop_delay_ms)
    %{state | playback: nil, page: :offers, stopping: Map.put(state.stopping, monitor, pipeline)}
  end

  defp stop_playback(%{playback: %{} = p} = state) do
    save_played(p)
    %{state | playback: nil}
  end

  defp stop_playback(state), do: state
end
