defmodule NervesPhone.State.Player do
  @moduledoc """
  Playback: what's playing, and the controls.

    * `:play_context` plays a playlist or album from a random track,
      `:play_track` from a given track. Either way it's shuffled.
    * `:toggle_play`, `:next`, `:previous` (on screen, and play/pause on the
      power button too).
    * `:volume_up`, `:volume_down` (the volume buttons).

  The backend is polled every two seconds for what's playing. Each poll
  also checks that playback is still on plain shuffle and turns it back on
  if something changed it: the player always shuffles and never smart
  shuffles.
  """

  use Solve.Controller,
    events: [:play_context, :play_track, :toggle_play, :next, :previous, :volume_up, :volume_down]

  alias NervesPhone.Audio.Volume
  alias NervesPhone.Music.{Backend, Covers}

  @poll_ms 2_000
  # After a command, polls don't override what it changed for this long, so
  # the screen doesn't flick back before the service catches up.
  @hold_ms 3_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :poll)

    %{
      device_ready: false,
      playback: nil,
      polling?: false,
      pending: nil,
      error: nil,
      cover_url: nil,
      volume: Volume.level(),
      hold_until: 0
    }
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    playback = state.playback
    track = playback && playback.track

    %{
      device_ready: state.device_ready,
      context_uri: playback && playback.context_uri,
      track: track,
      is_playing: playback != nil and playback.is_playing,
      progress_ms: if(playback, do: playback.progress_ms, else: 0),
      pending: state.pending,
      error: state.error,
      cover: track && Covers.path(track.image_url),
      volume: state.volume,
      volume_steps: Volume.steps()
    }
  end

  def play_context(%{uri: uri, total: total}, state),
    do: command(state, {:play, uri}, fn b -> b.play(uri, {:random, total}) end)

  def play_track(%{context_uri: context, track_uri: track}, state),
    do: command(state, {:play, context}, fn b -> b.play(context, {:track, track}) end)

  def next(_payload, state), do: command(state, :next, & &1.next())
  def previous(_payload, state), do: command(state, :previous, & &1.previous())

  def toggle_play(_payload, %{playback: %{is_playing: playing?} = playback} = state) do
    state
    |> command(:toggle, fn b -> if playing?, do: b.pause(), else: b.resume() end)
    |> Map.merge(%{
      playback: %{playback | is_playing: not playing?},
      hold_until: now() + @hold_ms
    })
  end

  def toggle_play(_payload, state), do: state

  def volume_up(_payload, state), do: %{state | volume: Volume.up()}
  def volume_down(_payload, state), do: %{state | volume: Volume.down()}

  def handle_info(:poll, %{polling?: true} = state), do: state

  def handle_info(:poll, state) do
    if Backend.impl().setup_hint() == nil do
      controller = self()
      async(fn -> send(controller, {:polled, safely(fn -> Backend.impl().playback() end)}) end)
      %{state | polling?: true}
    else
      Process.send_after(self(), :poll, @poll_ms * 5)
      state
    end
  end

  def handle_info({:polled, result}, state) do
    Process.send_after(self(), :poll, @poll_ms)
    state = %{state | polling?: false}

    case result do
      {:ok, %{device_ready: ready, playback: playback}} ->
        enforce_shuffle(playback)
        want_cover(state.playback, playback)
        %{state | device_ready: ready, playback: hold(state, playback)}

      {:error, _reason} ->
        state
    end
  end

  def handle_info({:done, action, result}, state) do
    send(self(), :poll)

    case result do
      :ok -> %{state | pending: nil, error: nil}
      {:error, reason} -> %{state | pending: nil, error: describe(action, reason)}
    end
  end

  def handle_info({:cover_ready, url}, state), do: %{state | cover_url: url}

  def handle_info(_message, state), do: state

  # Runs the backend call in a task and reports back with {:done, ...}.
  defp command(state, action, fun) do
    controller = self()
    backend = Backend.impl()
    async(fn -> send(controller, {:done, action, safely(fn -> fun.(backend) end)}) end)
    %{state | pending: action, error: nil}
  end

  # Right after play/pause, keep showing what was asked for.
  defp hold(%{playback: %{is_playing: asked}} = state, %{} = playback) do
    if now() < state.hold_until, do: %{playback | is_playing: asked}, else: playback
  end

  defp hold(_state, playback), do: playback

  defp enforce_shuffle(%{track: track} = playback) when track != nil do
    if not playback.shuffle or playback.smart_shuffle,
      do: async(fn -> Backend.impl().ensure_shuffle() end)
  end

  defp enforce_shuffle(_playback), do: :ok

  # Ask for the cover once, when the track changes.
  defp want_cover(old, %{track: %{image_url: url}}) when is_binary(url) do
    if get_in(old || %{}, [:track, :image_url]) != url, do: Covers.want([url])
  end

  defp want_cover(_old, _playback), do: :ok

  defp describe(_action, :no_device), do: "The phone isn't connected to the music service yet."
  defp describe(_action, :not_logged_in), do: "Not logged in."
  defp describe(_action, {:http, 403, _}), do: "Refused: playback needs Premium."
  defp describe(_action, {:http, status, message}), do: "Error #{status}: #{message}"
  defp describe(_action, reason), do: "Couldn't do that: #{inspect(reason)}"

  defp now, do: System.monotonic_time(:millisecond)

  defp async(fun), do: Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fun)

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
