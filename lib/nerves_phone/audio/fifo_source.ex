defmodule NervesPhone.Audio.FifoSource do
  @moduledoc """
  A Membrane source that reads raw PCM from a FIFO on demand.

  Reading only as much as the sink asks for is what paces librespot: its
  pipe backend writes as fast as it can, and blocks once the FIFO is full.
  The FIFO is opened read-write, so the open doesn't wait for a writer and
  reads never hit end-of-file when librespot closes its end between tracks.
  Blocking reads happen in a linked reader process.
  """

  use Membrane.Source

  alias Membrane.{Buffer, RawAudio}

  # librespot's pipe backend with --format S16.
  @format %RawAudio{channels: 2, sample_rate: 44_100, sample_format: :s16le}
  @frame_bytes 4
  @max_read 16_384

  def_options path: [spec: Path.t(), description: "The FIFO to read"]

  def_output_pad :output, accepted_format: RawAudio, flow_control: :manual, demand_unit: :bytes

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{path: opts.path, reader: nil, reading?: false, leftover: <<>>}}
  end

  @impl true
  def handle_setup(_ctx, state) do
    parent = self()
    reader = spawn_link(fn -> reader_init(parent, state.path) end)
    {[], %{state | reader: reader}}
  end

  @impl true
  def handle_playing(_ctx, state), do: {[stream_format: {:output, @format}], state}

  @impl true
  def handle_demand(:output, size, :bytes, _ctx, state) do
    if state.reading? do
      {[], state}
    else
      send(state.reader, {:read, min(size, @max_read)})
      {[], %{state | reading?: true}}
    end
  end

  @impl true
  def handle_info({:pcm, data}, _ctx, state) do
    # Only whole frames go out; a partial frame waits for the next read.
    data = state.leftover <> data
    whole = byte_size(data) - rem(byte_size(data), @frame_bytes)
    <<frames::binary-size(^whole), leftover::binary>> = data
    state = %{state | reading?: false, leftover: leftover}

    if frames == <<>>,
      do: {[redemand: :output], state},
      else: {[buffer: {:output, %Buffer{payload: frames}}, redemand: :output], state}
  end

  defp reader_init(parent, path) do
    {:ok, fd} = :file.open(path, [:read, :write, :raw, :binary])
    reader_loop(parent, fd)
  end

  defp reader_loop(parent, fd) do
    receive do
      {:read, size} ->
        {:ok, data} = :file.read(fd, size)
        send(parent, {:pcm, data})
        reader_loop(parent, fd)
    end
  end
end
