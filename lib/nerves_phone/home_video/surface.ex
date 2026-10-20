defmodule NervesPhone.HomeVideo.Surface do
  @moduledoc """
  Where video from the home cluster lands on this phone: the endpoint of
  the phone's `:display` capability (`NervesPhone.HomeVideo.Display`).

  home_base's `Home.Media.VideoSink` decodes the stream on this phone and
  sends each RGB frame here as `{:video_frame, owner, target, frame}`, as
  it would to a display's compositor. Instead of a second renderer, the
  frame goes to the video element of the phone's own UI that the Home
  Video app shows (`set_target/1`); while there is none, frames are
  dropped. So is every frame a newer one has overtaken while the UI was
  busy: it shows the latest picture rather than queueing them. The frames
  are Venus's DMA-BUF buffers (see `config :home_base, video:`), which the
  decoder needs back, so a dropped one is released at once.

  The subscriber (the app's controller) hears

    * `{:home_video, :started, owner}` with the first frame of a stream,
      `owner` being the `NervesPhone.HomeVideo.Broadcast` that sends it,
    * `{:home_video, :frames, %{fps: f, size: {w, h}, frames: n, dropped: n}}`
      every second while frames come (`frames` shown, `dropped` overtaken),
    * `{:home_video, :stopped}` once none have come for a while.
  """

  use GenServer

  @tick_ms 1_000
  # No frame for this long and the stream is over.
  @idle_ms 2_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends the stream's news to the calling process."
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "The video element frames go to, or nil to drop them."
  def set_target(target), do: GenServer.cast(__MODULE__, {:set_target, target})

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     %{
       subscriber: nil,
       target: nil,
       owner: nil,
       size: nil,
       frames: 0,
       dropped: 0,
       window: 0,
       last_at: nil
     }}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state), do: {:reply, :ok, %{state | subscriber: pid}}

  @impl GenServer
  def handle_cast({:set_target, target}, state), do: {:noreply, %{state | target: target}}

  @impl GenServer
  def handle_info({:video_frame, owner, _target, %VideoInterop.Frame{} = frame}, state) do
    {frame, skipped} = latest(frame, 0)

    state =
      if owner != state.owner do
        notify(state, {:home_video, :started, owner})
        %{state | owner: owner, frames: 0, dropped: 0, window: 0}
      else
        state
      end

    submit(state.target, frame)

    {:noreply,
     %{
       state
       | size: {frame.visible_rect.width, frame.visible_rect.height},
         frames: state.frames + 1,
         dropped: state.dropped + skipped,
         window: state.window + 1,
         last_at: now()
     }}
  end

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)

    state =
      cond do
        state.owner == nil ->
          state

        now() - state.last_at > @idle_ms ->
          notify(state, {:home_video, :stopped})
          %{state | owner: nil, size: nil}

        true ->
          fps = state.window * 1_000 / @tick_ms

          notify(
            state,
            {:home_video, :frames,
             %{fps: fps, size: state.size, frames: state.frames, dropped: state.dropped}}
          )

          %{state | window: 0}
      end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp latest(frame, skipped) do
    receive do
      {:video_frame, _owner, _target, %VideoInterop.Frame{} = newer} ->
        VideoInterop.release(frame)
        latest(newer, skipped + 1)
    after
      0 -> {frame, skipped}
    end
  end

  # Emerge owns a frame once submit_video_frame returns; one it never gets
  # is released here.
  defp submit(nil, frame), do: VideoInterop.release(frame)

  defp submit(target, frame) do
    case Process.whereis(NervesPhone.UI) do
      nil -> VideoInterop.release(frame)
      viewport -> Emerge.submit_video_frame(viewport, target, frame)
    end
  end

  defp notify(%{subscriber: nil}, _message), do: :ok
  defp notify(%{subscriber: pid}, message), do: send(pid, message)

  defp now, do: System.monotonic_time(:millisecond)
end
