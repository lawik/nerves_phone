defmodule NervesPhone.HomeVideo.CameraFeed do
  @moduledoc """
  One of the phone's cameras as an H.264 feed for home_base's
  `Home.Media.H264Relay`, which sends it on without decoding it.

  The first subscriber starts a stream (`Fp3Camera.start_stream/2`): the
  camera ISP's 1280x720 frames (white balanced, colour and gamma
  corrected), encoded in place by Venus, the phone's hardware encoder,
  with a keyframe every second, served on a local TCP port. The feed reads that stream, cuts
  it into access units (`NervesPhone.HomeVideo.AnnexB`) and sends each to
  every subscriber as

      {:h264_relay, feed, {:au, annexb_payload, pts_ns, keyframe?}}

  starting at a keyframe, with the stream's SPS and PPS in front of it if
  the keyframe doesn't carry them.

  A feed is started for each session (`start/1`, under
  `NervesPhone.HomeVideo.Cameras`). When its last subscriber goes, or if
  none comes, it stops the stream and exits, and the camera is free
  again. If the camera can't start or its stream ends, it exits too,
  which ends the relays' streams and so the session.
  """

  use GenServer, restart: :temporary

  require Logger

  alias NervesPhone.HomeVideo.AnnexB

  # Two phones in a call each send a stream through the Wi-Fi access
  # point. At 3 Mbit/s the link lost packets until the call fell apart; at
  # 1 Mbit/s both ran at 30 fps with no loss.
  @bitrate 1_000_000
  # Venus encodes the ISP's buffers in place at a width that's a multiple
  # of 128.
  @width 1280
  @height 720
  @connect_timeout_ms 10_000
  @connect_retry_ms 200
  # A feed nobody subscribes to in this time exits.
  @unused_ms 15_000

  @doc "A new feed for `camera` (`:rear` or `:front`)."
  @spec start(Fp3Camera.camera()) :: {:ok, pid()} | {:error, term()}
  def start(camera),
    do: DynamicSupervisor.start_child(NervesPhone.HomeVideo.Cameras, {__MODULE__, camera})

  @doc false
  def start_link(camera), do: GenServer.start_link(__MODULE__, camera)

  @impl GenServer
  def init(camera) do
    # To stop the stream however the feed exits.
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :unused?, @unused_ms)

    {:ok,
     %{
       camera: camera,
       stream: nil,
       socket: nil,
       splitter: AnnexB.new(),
       # pid => {monitor, :waiting | :sending}
       subscribers: %{},
       parameter_sets: %{},
       started_at: nil
     }}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    if state.subscribers == %{}, do: send(self(), :start)
    {:reply, :ok, put_in(state.subscribers[pid], {Process.monitor(pid), :waiting})}
  end

  @impl GenServer
  def handle_info(:unused?, %{subscribers: subscribers} = state) when subscribers == %{},
    do: {:stop, :normal, state}

  def handle_info(:unused?, state), do: {:noreply, state}

  # Starting the stream takes a second or more, longer than the relay's
  # subscribe call waits. If it fails the feed stops, which ends the
  # relays' streams and so the session.
  def handle_info(:start, %{subscribers: subscribers} = state) when subscribers == %{},
    do: {:noreply, state}

  def handle_info(:start, state) do
    case ensure_streaming(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, {:shutdown, {:camera, reason}}, state}
    end
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    {aus, splitter} = AnnexB.push(state.splitter, data)
    {:noreply, Enum.reduce(aus, %{state | splitter: splitter}, &relay/2)}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("Camera #{state.camera}: the stream closed")
    {:stop, {:shutdown, :stream_closed}, stop_streaming(state)}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = drop(state, pid)
    if state.subscribers == %{}, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state), do: stop_streaming(state)

  defp ensure_streaming(%{socket: nil} = state) do
    with {:ok, stream} <-
           Fp3Camera.start_stream(state.camera, bitrate: @bitrate, width: @width, height: @height),
         {:ok, socket} <- connect(port(stream), deadline()) do
      Logger.info("Camera #{state.camera}: streaming")

      {:ok,
       %{
         state
         | stream: stream,
           socket: socket,
           splitter: AnnexB.new(),
           started_at: System.monotonic_time(:nanosecond)
       }}
    else
      {:error, reason} ->
        {:error, reason, stop_streaming(state)}
    end
  end

  defp ensure_streaming(state), do: {:ok, state}

  defp port(stream) do
    case Enum.find(Fp3Camera.streams(), &(&1.ref == stream)) do
      %{port: port} -> port
      nil -> nil
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @connect_timeout_ms

  defp connect(nil, _deadline), do: {:error, :no_stream}

  # The stream's server may still be starting when start_stream returns.
  defp connect(port, deadline) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: true, nodelay: true], 1_000) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@connect_retry_ms)
          connect(port, deadline)
        else
          {:error, {:connect, reason}}
        end
    end
  end

  # Stopped before the socket closes, so the stream isn't restarted for
  # the next client.
  defp stop_streaming(state) do
    if state.stream, do: Fp3Camera.stop_stream(state.stream)
    if state.socket, do: :gen_tcp.close(state.socket)
    %{state | stream: nil, socket: nil, splitter: AnnexB.new(), parameter_sets: %{}}
  end

  defp drop(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _subscribers} ->
        state

      {{monitor, _status}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | subscribers: subscribers}
        if subscribers == %{}, do: stop_streaming(state), else: state
    end
  end

  defp relay(au, state) do
    state = remember_parameter_sets(state, au.payload)
    pts = System.monotonic_time(:nanosecond) - state.started_at

    subscribers =
      Map.new(state.subscribers, fn
        {pid, {monitor, :waiting}} when au.keyframe? ->
          send(
            pid,
            {:h264_relay, self(), {:au, with_parameter_sets(au.payload, state), pts, true}}
          )

          {pid, {monitor, :sending}}

        {pid, {monitor, :sending}} ->
          send(pid, {:h264_relay, self(), {:au, au.payload, pts, au.keyframe?}})
          {pid, {monitor, :sending}}

        waiting ->
          waiting
      end)

    %{state | subscribers: subscribers}
  end

  defp remember_parameter_sets(state, payload) do
    sets =
      for <<_::3, type::5, _::binary>> = nalu <- nalus(payload),
          type in [7, 8],
          into: state.parameter_sets,
          do: {type, nalu}

    %{state | parameter_sets: sets}
  end

  defp with_parameter_sets(payload, %{parameter_sets: sets}) do
    types = for <<_::3, type::5, _::binary>> <- nalus(payload), do: type
    missing = for type <- [7, 8], type not in types, nalu = sets[type], do: [<<0, 0, 0, 1>>, nalu]
    IO.iodata_to_binary([missing, payload])
  end

  defp nalus(payload) do
    payload |> :binary.split(<<0, 0, 0, 1>>, [:global]) |> Enum.reject(&(&1 == <<>>))
  end
end
