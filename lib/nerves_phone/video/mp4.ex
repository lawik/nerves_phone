defmodule NervesPhone.Video.MP4 do
  @moduledoc """
  An index of an MP4 or QuickTime file's samples, for playing from any
  point.

  Membrane's MP4 demuxer reads a file from the start, so it can't seek.
  This reads the file's `moov` box once (with Membrane's box parser) and
  lists, for the first H.264 track and the first AAC track, every sample's
  place in the file, size and timestamps, and which video samples are
  keyframes. `NervesPhone.Video.MP4Source` then reads samples straight from
  their offsets.

  Indexing a long file takes a few seconds (the `moov` box of an hour of
  video is megabytes), so indexes are kept in `state_dir/video_index`,
  keyed by the file's path, size and modification time.

  Each track's samples are packed into one binary, 29 bytes a sample:

      <<offset::64, size::32, dts_ns::signed-64, pts_ns::signed-64, keyframe::8>>

  Edit lists are ignored, as Membrane's demuxer does.
  """

  alias Membrane.MP4.Container
  alias Membrane.MP4.MovieBox.SampleTableBox

  @sample_bytes 29
  @version 1

  @type track :: %{
          format: struct(),
          count: non_neg_integer(),
          samples: binary(),
          keyframes: tuple()
        }

  @type t :: %{
          duration_ns: non_neg_integer(),
          video: track() | nil,
          audio: track() | nil
        }

  @doc "The index of `path`, from the cache or read now."
  @spec index(Path.t()) :: {:ok, t()} | {:error, term()}
  def index(path) do
    with {:ok, stat} <- File.stat(path, time: :posix) do
      cache = cache_path(path, stat)

      case read_cache(cache) do
        {:ok, index} ->
          {:ok, index}

        :miss ->
          with {:ok, index} <- build(path) do
            write_cache(cache, index)
            {:ok, index}
          end
      end
    end
  end

  @doc "Sample `n` of a track: `{offset, size, dts_ns, pts_ns, keyframe?}`."
  def sample(%{samples: samples}, n) do
    <<offset::64, size::32, dts::signed-64, pts::signed-64, key::8>> =
      binary_part(samples, n * @sample_bytes, @sample_bytes)

    {offset, size, dts, pts, key == 1}
  end

  @doc """
  Where to start a track to play from `at_ns`: for video, the last keyframe
  at or before it (decoding must start at one); for sound, the first sample
  at or after it.
  """
  def start_sample(%{count: 0}, _kind, _at_ns), do: 0

  def start_sample(track, :video, at_ns) do
    track.keyframes
    |> Tuple.to_list()
    |> Enum.take_while(fn n -> elem(sample(track, n), 3) <= at_ns end)
    |> List.last()
    |> Kernel.||(0)
  end

  def start_sample(track, :audio, at_ns) do
    Enum.find(0..(track.count - 1), track.count, fn n -> elem(sample(track, n), 3) >= at_ns end)
  end

  # ---------- Reading the file ----------

  defp build(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        with {:ok, moov} <- read_moov(file) do
          index_moov(moov)
        end
      after
        File.close(file)
      end
    end
  rescue
    error -> {:error, {:unreadable, Exception.message(error)}}
  end

  # The top-level boxes' headers, until `moov`; then `moov` itself.
  defp read_moov(file, pos \\ 0) do
    case :file.pread(file, pos, 16) do
      {:ok, <<size::32, "moov", _::binary>>} when size >= 8 ->
        parse_box(file, pos, size)

      {:ok, <<1::32, "moov", size::64>>} ->
        parse_box(file, pos, size)

      {:ok, <<1::32, _type::binary-4, size::64>>} when size >= 16 ->
        read_moov(file, pos + size)

      {:ok, <<size::32, _type::binary-4, _::binary>>} when size >= 8 ->
        read_moov(file, pos + size)

      _end_or_garbage ->
        {:error, :no_moov}
    end
  end

  defp parse_box(file, pos, size) do
    {:ok, data} = :file.pread(file, pos, size)
    {boxes, _rest} = Container.parse!(data, Container.Schema.Default.schema())
    {:ok, boxes[:moov]}
  end

  defp index_moov(moov) do
    mvhd = moov.children[:mvhd].fields

    tracks =
      for {:trak, trak} <- moov.children do
        mdia = trak.children[:mdia]
        stbl = mdia.children[:minf].children[:stbl]
        timescale = mdia.children[:mdhd].fields.timescale
        table = SampleTableBox.unpack(stbl, timescale)
        {table, stbl, timescale}
      end

    video =
      Enum.find(tracks, fn {table, _, _} -> match?(%Membrane.H264{}, table.sample_description) end)

    audio =
      Enum.find(tracks, fn {table, _, _} -> match?(%Membrane.AAC{}, table.sample_description) end)

    if video do
      {:ok,
       %{
         version: @version,
         duration_ns: div(mvhd.duration * 1_000_000_000, mvhd.timescale),
         video: track(video),
         audio: audio && track(audio)
       }}
    else
      {:error, :no_h264_video}
    end
  end

  defp track({table, stbl, timescale}) do
    sizes = table.sample_sizes

    offsets = sample_offsets(table.chunk_offsets, table.samples_per_chunk, sizes)
    deltas = runs(table.decoding_deltas, :sample_delta)
    composition = runs(table.composition_offsets, :sample_composition_offset)

    keyframes =
      case stbl.children[:stss] do
        nil -> nil
        stss -> MapSet.new(stss.fields.entry_list, & &1.sample_number)
      end

    {packed, _dts, keys, count} =
      [offsets, sizes, deltas, composition]
      |> Enum.zip()
      |> Enum.reduce({[], 0, [], 0}, fn {offset, size, delta, comp}, {acc, dts, keys, n} ->
        key? = keyframes == nil or MapSet.member?(keyframes, n + 1)
        dts_ns = div(dts * 1_000_000_000, timescale)
        pts_ns = div((dts + comp) * 1_000_000_000, timescale)

        sample =
          <<offset::64, size::32, dts_ns::signed-64, pts_ns::signed-64,
            if(key?, do: 1, else: 0)::8>>

        {[acc | sample], dts + delta, if(key?, do: [n | keys], else: keys), n + 1}
      end)

    %{
      format: table.sample_description,
      count: count,
      samples: IO.iodata_to_binary(packed),
      keyframes: keys |> Enum.reverse() |> List.to_tuple()
    }
  end

  # Expands `[%{sample_count: n, field => v}]` runs into one value a sample.
  defp runs(entries, field),
    do:
      Stream.flat_map(entries, fn entry ->
        Stream.duplicate(Map.fetch!(entry, field), entry.sample_count)
      end)

  # Each sample's file offset: chunks hold runs of consecutive samples.
  defp sample_offsets(chunk_offsets, samples_per_chunk, sizes) do
    counts = chunk_sample_counts(samples_per_chunk, length(chunk_offsets))

    {offsets, _sizes} =
      chunk_offsets
      |> Enum.zip(counts)
      |> Enum.flat_map_reduce(sizes, fn {chunk_offset, count}, sizes ->
        {chunk_sizes, rest} = Enum.split(sizes, count)

        {offsets, _end} =
          Enum.map_reduce(chunk_sizes, chunk_offset, fn size, at -> {at, at + size} end)

        {offsets, rest}
      end)

    offsets
  end

  defp chunk_sample_counts(entries, chunk_count) do
    entries
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [%{first_chunk: first, samples_per_chunk: n}, %{first_chunk: next}] ->
        List.duplicate(n, next - first)

      [%{first_chunk: first, samples_per_chunk: n}] ->
        List.duplicate(n, chunk_count - first + 1)
    end)
  end

  # ---------- Cache ----------

  defp cache_path(path, stat) do
    key =
      :crypto.hash(:sha256, "#{path}\0#{stat.size}\0#{stat.mtime}")
      |> Base.url_encode64(padding: false)

    Path.join([NervesPhone.state_dir(), "video_index", key])
  end

  defp read_cache(cache) do
    with {:ok, data} <- File.read(cache),
         %{version: @version} = index <- :erlang.binary_to_term(data, [:safe]) do
      {:ok, index}
    else
      _ -> :miss
    end
  rescue
    _ -> :miss
  end

  defp write_cache(cache, index) do
    File.mkdir_p(Path.dirname(cache))
    tmp = cache <> ".tmp"
    with :ok <- File.write(tmp, :erlang.term_to_binary(index)), do: File.rename(tmp, cache)
  end
end
