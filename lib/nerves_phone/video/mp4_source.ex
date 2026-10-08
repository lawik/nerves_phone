defmodule NervesPhone.Video.MP4Source do
  @moduledoc """
  Reads an MP4 file's samples straight from their offsets, using a
  `NervesPhone.Video.MP4` index, from any point in the file.

  Link `Pad.ref(:output, :video)` and, if the index has sound,
  `Pad.ref(:output, :audio)`. Each track has its own cursor and goes as
  fast as its pad is demanded, so sound held back at the player's gate
  never stalls the picture. The stream formats and buffers are the same as
  Membrane's MP4 demuxer gives (`avc1` H.264, ESDS AAC), so its parsers go
  next.

  Video starts at the last keyframe at or before `start_ns` (decoding has
  to start at one); sound at the first sample at or after it.
  """

  use Membrane.Source

  alias Membrane.{Buffer, Pad}
  alias NervesPhone.Video.MP4

  def_options(
    path: [spec: Path.t()],
    index: [spec: MP4.t()],
    start_ns: [spec: non_neg_integer(), default: 0]
  )

  def_output_pad(:output,
    availability: :on_request,
    flow_control: :manual,
    demand_unit: :buffers,
    accepted_format: _any
  )

  @impl true
  def handle_init(_ctx, opts) do
    cursors =
      for kind <- [:video, :audio], track = Map.get(opts.index, kind), track != nil, into: %{} do
        {kind, MP4.start_sample(track, kind, opts.start_ns)}
      end

    {[], %{path: opts.path, index: opts.index, cursors: cursors, file: nil, ended: MapSet.new()}}
  end

  @impl true
  # A raw file closes when this process exits (and only this process may
  # close it, so it isn't handed to the resource guard).
  def handle_setup(_ctx, state) do
    {:ok, file} = File.open(state.path, [:read, :binary, :raw])
    {[], %{state | file: file}}
  end

  @impl true
  def handle_playing(ctx, state) do
    actions =
      for {Pad.ref(:output, kind) = pad, _data} <- ctx.pads do
        {:stream_format, {pad, state.index[kind].format}}
      end

    {actions, state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, kind) = pad, size, :buffers, _ctx, state) do
    track = state.index[kind]
    first = state.cursors[kind]
    last = min(first + size, track.count) - 1

    cond do
      MapSet.member?(state.ended, kind) ->
        {[], state}

      first >= track.count ->
        {[end_of_stream: pad], %{state | ended: MapSet.put(state.ended, kind)}}

      true ->
        samples = for n <- first..last, do: MP4.sample(track, n)

        {:ok, payloads} =
          :file.pread(state.file, Enum.map(samples, fn {o, s, _, _, _} -> {o, s} end))

        buffers =
          Enum.zip_with(samples, payloads, fn {_o, _s, dts, pts, _key}, payload ->
            %Buffer{payload: payload, dts: dts, pts: pts}
          end)

        state = put_in(state.cursors[kind], last + 1)

        if last + 1 >= track.count,
          do:
            {[buffer: {pad, buffers}, end_of_stream: pad],
             %{state | ended: MapSet.put(state.ended, kind)}},
          else: {[buffer: {pad, buffers}], state}
    end
  end
end
