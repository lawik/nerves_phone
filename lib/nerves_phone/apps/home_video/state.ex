defmodule NervesPhone.Apps.HomeVideo.State do
  @moduledoc """
  The Home Video app's controller: the cameras and phones in the home
  cluster, and the stream this phone is showing.

  Show starts a camera, wherever it is, on this phone; calling another
  phone sends each one's front camera to the other
  (`NervesPhone.HomeVideo.Broadcast`). When a stream's first frame reaches
  this phone (`NervesPhone.HomeVideo.Surface`), the app opens by itself
  and takes the whole screen, with the stream's numbers on top: frames
  this phone decoded, from the frames themselves, and bitrate, loss,
  jitter, round trip and recovered packets from the session's RTCP, asked
  of the broadcast or call that runs it, wherever that is. The screen stays on
  while a stream shows.

  Each stream gets its own video target, so the last one's frame never
  shows.
  """

  use Solve.Controller, events: [:opened, :broadcast, :call, :stop, :toggle_stats]

  alias NervesPhone.HomeVideo.{Broadcast, Surface}

  @tick_ms 1_000
  # The camera and phone lists are refreshed this often while idle.
  @refresh_every 3
  # Seconds of bitrate kept for the graph.
  @history 40
  @targets for n <- 0..15, do: :"home_video_#{n}"

  @impl Solve.Controller
  def init(_params, _dependencies) do
    :ok = Surface.subscribe()
    Process.send_after(self(), :tick, @tick_ms)

    %{
      running: false,
      cameras: [],
      phones: [],
      nodes: [],
      starting: nil,
      error: nil,
      stream: nil,
      show_stats: true,
      ticks: 0,
      next_target: 0
    }
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    Map.take(state, [:running, :cameras, :phones, :nodes, :starting, :error, :show_stats])
    |> Map.put(:stream, state.stream && Map.drop(state.stream, [:owner, :octets_at]))
  end

  def opened(_payload, state), do: refresh(state)

  def broadcast(camera, %{running: true} = state) do
    me = self()

    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
      send(me, {:broadcast_result, camera, Broadcast.start(camera)})
    end)

    %{state | starting: camera, error: nil}
  end

  def broadcast(_camera, state), do: state

  def call(peer, %{running: true} = state) do
    me = self()

    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
      send(me, {:broadcast_result, {:call, peer}, Broadcast.call(peer)})
    end)

    %{state | starting: {:call, peer}, error: nil}
  end

  def call(_peer, state), do: state

  def stop(_payload, %{stream: %{owner: owner}} = state) do
    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn -> Broadcast.stop(owner) end)
    state
  end

  def stop(_payload, state), do: state

  def toggle_stats(_payload, state), do: %{state | show_stats: not state.show_stats}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    state = %{state | ticks: state.ticks + 1}

    cond do
      state.stream != nil ->
        fetch_stats(state.stream.owner)
        state

      rem(state.ticks, @refresh_every) == 0 ->
        refresh(state)

      true ->
        state
    end
  end

  def handle_info({:broadcast_result, camera, :ok}, %{starting: camera} = state),
    do: %{state | starting: nil}

  def handle_info({:broadcast_result, camera, {:error, reason}}, %{starting: camera} = state),
    do: %{state | starting: nil, error: "Couldn't start it: #{inspect(reason)}"}

  def handle_info({:broadcast_result, _camera, _result}, state), do: state

  def handle_info({:home_video, :started, owner}, state) do
    target = Enum.at(@targets, state.next_target)
    Surface.set_target(target)
    Fp3Extras.Screen.keep_awake(true)
    Solve.dispatch(NervesPhone.State, :shell, :open, NervesPhone.Apps.HomeVideo)

    stream = %{
      owner: owner,
      target: target,
      kind: nil,
      camera: nil,
      phones: 0,
      started_at: nil,
      fps: 0.0,
      size: nil,
      frames: 0,
      dropped: 0,
      kbps: 0,
      kbps_history: [],
      lost: 0,
      loss: 0.0,
      jitter_ms: nil,
      rtt_ms: nil,
      recovered: 0,
      keyframes: 0,
      octets_at: nil
    }

    %{
      state
      | stream: stream,
        starting: nil,
        error: nil,
        next_target: rem(state.next_target + 1, length(@targets))
    }
  end

  def handle_info({:home_video, :frames, frames}, %{stream: %{} = stream} = state),
    do: %{state | stream: Map.merge(stream, frames)}

  def handle_info({:home_video, :stopped}, state) do
    Surface.set_target(nil)
    Fp3Extras.Screen.keep_awake(false)
    refresh(%{state | stream: nil})
  end

  def handle_info({:home_video_stats, owner, stats}, %{stream: %{owner: owner}} = state),
    do: %{state | stream: apply_stats(state.stream, stats)}

  def handle_info(_message, state), do: state

  # Asked from a task: the broadcast may be on another node, and slow.
  defp fetch_stats(owner) do
    me = self()

    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
      send(me, {:home_video_stats, owner, Broadcast.stats(owner)})
    end)
  end

  defp apply_stats(stream, nil), do: stream

  defp apply_stats(stream, stats) do
    mine = Broadcast.own_display()
    # The stream this phone shows: in a call, the other phone's camera.
    shown = Enum.find(stats.streams, %{camera: nil, session: %{}}, &(mine in &1.sinks))
    source = get_in(shown, [:session, :source]) || %{}
    sink = get_in(shown, [:session, :sinks, mine]) || %{}
    report = get_in(source, [:receivers, mine]) || %{}
    now = System.monotonic_time(:millisecond)
    octets = Map.get(source, :octets)

    kbps =
      case {stream.octets_at, octets} do
        {{before, at}, octets} when is_integer(octets) and now > at ->
          round((octets - before) * 8 / (now - at))

        _ ->
          stream.kbps
      end

    %{
      stream
      | kind: stats.kind,
        camera: shown.camera,
        phones: stats.streams |> Enum.flat_map(& &1.sinks) |> Enum.uniq() |> length(),
        started_at: stats.started_at,
        kbps: kbps,
        kbps_history: Enum.take([kbps | stream.kbps_history], @history),
        lost: Map.get(sink, :lost, 0),
        loss: Map.get(sink, :fraction_lost, 0.0),
        jitter_ms: Map.get(sink, :jitter_ms),
        rtt_ms: Map.get(report, :rtt_ms),
        recovered: Map.get(sink, :recovered, 0),
        keyframes: Map.get(source, :keyframes_forced, 0),
        octets_at: if(is_integer(octets), do: {octets, now}, else: stream.octets_at)
    }
  end

  defp refresh(state) do
    if NervesPhone.Home.running?() do
      %{
        state
        | running: true,
          cameras: Enum.map(Home.Registry.list(kind: :video_in), &describe/1),
          phones: Enum.map(Broadcast.displays(), &describe/1),
          nodes: Node.list()
      }
    else
      %{state | running: false, cameras: [], phones: [], nodes: []}
    end
  end

  defp describe(%{ref: {node, id} = ref} = info) do
    %{
      ref: ref,
      name: "#{info.device_id || host(node)} · #{id}",
      node: node,
      busy: info.status != :idle,
      held_by: info.held_by
    }
  end

  defp host(node), do: node |> Atom.to_string() |> String.split("@") |> List.last()
end
