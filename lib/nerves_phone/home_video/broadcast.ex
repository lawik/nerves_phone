defmodule NervesPhone.HomeVideo.Broadcast do
  @moduledoc """
  Video between the devices of the home cluster: a camera shown on this
  phone, or a video call between two phones.

    * `start/1` shows a camera on this phone: an H.264 `Home.Media.Session`
      from the camera to this phone's `"phone_video"` display
      (`NervesPhone.HomeVideo.Display`). A phone's camera is encoded by
      its hardware encoder, any other by its node, and this phone decodes.
    * `call/1` is a call with another phone: two sessions, this phone's
      front camera to the other's display and the other's front camera to
      this one's. Video only, for now.

  Cameras are opened only while a session holds them. The sessions hold
  and renew the leases; when one ends (its camera's node goes, a revoke,
  a hang-up on either phone), the others end too.

  The frames name this process as their owner, so a phone showing them can
  ask it for `stats/1`, wherever it runs.
  """

  use GenServer

  require Logger

  @display "phone_video"
  @call_camera "front"
  @bitrate 2_000_000

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Shows `camera` (`{node, id}`) on this phone. Ends what was on first."
  @spec start({node(), String.t()}) :: :ok | {:error, term()}
  def start(camera), do: GenServer.call(__MODULE__, {:start, camera}, 30_000)

  @doc "Calls the phone on `peer` (a node). Ends what was on first."
  @spec call(node()) :: :ok | {:error, term()}
  def call(peer), do: GenServer.call(__MODULE__, {:call, peer}, 30_000)

  @doc "Ends what `owner` runs, wherever it is."
  @spec stop(GenServer.server()) :: :ok
  def stop(owner \\ __MODULE__) do
    GenServer.call(owner, :stop, 5_000)
  catch
    :exit, _ -> :ok
  end

  @doc """
  What `owner` runs: `%{kind: :broadcast | :call, started_at:, streams:}`,
  each stream `%{camera:, sinks:, session:}` with `session` being
  `Home.Media.Session.stats/1`. Nil if nothing.
  """
  @spec stats(GenServer.server()) :: map() | nil
  def stats(owner) do
    GenServer.call(owner, :stats, 3_000)
  catch
    :exit, _ -> nil
  end

  @doc "The phones' video displays in the cluster."
  @spec displays() :: [map()]
  def displays, do: Enum.filter(Home.Registry.list(kind: :display), &(&1.cap.id == @display))

  @doc "This phone's video display."
  def own_display, do: {node(), @display}

  @impl GenServer
  def init(_opts), do: {:ok, nil}

  @impl GenServer
  def handle_call({:start, camera}, _from, state) do
    stop_all(state)
    reply(:broadcast, [{camera, [own_display()]}])
  end

  def handle_call({:call, peer}, _from, state) do
    stop_all(state)

    reply(:call, [
      {{node(), @call_camera}, [{peer, @display}]},
      {{peer, @call_camera}, [{node(), @display}]}
    ])
  end

  def handle_call(:stop, _from, state) do
    stop_all(state)
    {:reply, :ok, nil}
  end

  def handle_call(:stats, _from, nil), do: {:reply, nil, nil}

  def handle_call(:stats, _from, state) do
    streams =
      for stream <- state.streams do
        stats =
          try do
            Home.Media.Session.stats(stream.session)
          catch
            :exit, _ -> %{}
          end

        stream |> Map.take([:camera, :sinks]) |> Map.put(:session, stats)
      end

    {:reply, %{kind: state.kind, started_at: state.started_at, streams: streams}, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{streams: streams} = state) do
    if Enum.any?(streams, &(&1.monitor == ref)) do
      Logger.info("Home video #{state.kind} ended: #{inspect(reason)}")
      stop_all(state)
      {:noreply, nil}
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Starts every stream, or none.
  defp reply(kind, plan) do
    result =
      Enum.reduce_while(plan, {:ok, []}, fn {camera, displays}, {:ok, streams} ->
        case start_stream(camera, displays) do
          {:ok, stream} -> {:cont, {:ok, [stream | streams]}}
          {:error, reason} -> {:halt, {:error, reason, streams}}
        end
      end)

    case result do
      {:ok, streams} ->
        state = %{kind: kind, streams: streams, started_at: System.system_time(:millisecond)}
        {:reply, :ok, state}

      {:error, reason, started} ->
        stop_all(%{streams: started})
        {:reply, {:error, reason}, nil}
    end
  end

  defp start_stream(camera, displays) do
    with {:ok, source} <- Home.Lease.acquire(camera, purpose: "home video") do
      sinks = lease(displays)

      opts = [
        source: source,
        sinks: sinks,
        codec: :h264,
        bitrate: @bitrate,
        surface: {self(), :home_video}
      ]

      case sinks != [] && Home.Media.Session.start(opts) do
        {:ok, session} ->
          {:ok,
           %{
             session: session,
             monitor: Process.monitor(session),
             camera: camera,
             sinks: Enum.map(sinks, & &1.cap)
           }}

        failed ->
          # Leases the session didn't take over are still this process's.
          Enum.each([source | sinks], &Home.Lease.release/1)
          if failed, do: failed, else: {:error, :no_phones}
      end
    end
  end

  # Every display that can be leased; one that can't isn't shown on.
  defp lease(displays) do
    for ref <- displays,
        {:ok, lease} <- [Home.Lease.acquire(ref, purpose: "home video")],
        do: lease
  end

  defp stop_all(nil), do: :ok
  defp stop_all(%{streams: streams}), do: Enum.each(streams, &stop_stream/1)

  defp stop_stream(%{session: session, monitor: monitor}) do
    Process.demonitor(monitor, [:flush])
    Home.Media.Session.stop(session)
  catch
    :exit, _ -> :ok
  end
end
