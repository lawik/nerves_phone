defmodule NervesPhone.Kids.History do
  @moduledoc """
  Everything that's been watched on the phone, for good, in
  `state_dir/kids/history.jsonl`.

  Each watch is an entry: the video's path, title, show and kind (as they
  were then), when it started (by the phone's clock, which may be off
  before it's on the network), its length and how long it's played.
  Entries are in the order they started.

  The file only grows: a watch is written when it starts and again as it
  plays, one JSON line each time, and the last line for an entry wins. So
  a watch cut short by a power cut keeps the time written before it. At
  start, the file is rewritten with one line an entry once updates
  outnumber entries; nothing's ever dropped.
  """

  use GenServer

  require Logger

  @type entry :: %{
          id: String.t(),
          path: Path.t(),
          title: String.t() | nil,
          series: String.t() | nil,
          kind: String.t() | nil,
          started_at: String.t(),
          duration_s: non_neg_integer() | nil,
          watched_s: non_neg_integer()
        }

  @fields ~w(id path title series kind started_at duration_s watched_s)a

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every entry, oldest first."
  @spec all() :: [entry()]
  def all, do: GenServer.call(__MODULE__, :all)

  @doc """
  Starts an entry for a video (`:path`, `:title`, `:series`, `:kind`,
  `:duration_s`) and returns it.
  """
  @spec start(map()) :: entry()
  def start(video), do: GenServer.call(__MODULE__, {:start, video})

  @doc """
  Records how long an entry has played so far, and its video's length if
  it wasn't known when it started.
  """
  @spec watched(String.t(), non_neg_integer(), non_neg_integer() | nil) :: :ok
  def watched(id, seconds, duration_s \\ nil),
    do: GenServer.call(__MODULE__, {:watched, id, seconds, duration_s})

  @impl true
  def init(_opts) do
    {entries, lines} = load()

    if lines > 2 * length(entries) + 50, do: compact(entries)

    {:ok, %{entries: entries, index: index(entries)}}
  end

  @impl true
  def handle_call(:all, _from, state), do: {:reply, state.entries, state}

  def handle_call({:start, video}, _from, state) do
    entry = %{
      id: id(),
      path: video.path,
      title: video[:title],
      series: video[:series],
      kind: video[:kind],
      started_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      duration_s: video[:duration_s],
      watched_s: 0
    }

    append(entry)
    entries = state.entries ++ [entry]

    {:reply, entry,
     %{state | entries: entries, index: Map.put(state.index, entry.id, length(entries) - 1)}}
  end

  def handle_call({:watched, id, seconds, duration_s}, _from, state) do
    case state.index do
      %{^id => at} ->
        entry = Enum.at(state.entries, at)
        entry = %{entry | watched_s: seconds, duration_s: entry.duration_s || duration_s}
        append(entry)
        {:reply, :ok, %{state | entries: List.replace_at(state.entries, at, entry)}}

      _unknown ->
        {:reply, :ok, state}
    end
  end

  # ---------- The file ----------

  defp path, do: Path.join([NervesPhone.state_dir(), "kids", "history.jsonl"])

  # {entries in order of first appearance, lines read}
  defp load do
    case File.read(path()) do
      {:ok, data} ->
        lines = String.split(data, "\n", trim: true)

        {order, latest} =
          Enum.reduce(lines, {[], %{}}, fn line, {order, latest} ->
            case decode(line) do
              %{id: id} = entry ->
                order = if Map.has_key?(latest, id), do: order, else: [id | order]
                {order, Map.put(latest, id, entry)}

              nil ->
                # A line cut off by a power cut.
                {order, latest}
            end
          end)

        {order |> Enum.reverse() |> Enum.map(&latest[&1]), length(lines)}

      {:error, :enoent} ->
        {[], 0}

      {:error, reason} ->
        Logger.error("Couldn't read the watch history: #{:file.format_error(reason)}")
        {[], 0}
    end
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{"id" => id, "path" => path} = map} when is_binary(id) and is_binary(path) ->
        Map.new(@fields, fn field -> {field, map[Atom.to_string(field)]} end)
        |> Map.update!(:watched_s, &(&1 || 0))

      _bad ->
        nil
    end
  end

  defp append(entry) do
    File.mkdir_p(Path.dirname(path()))

    case File.write(path(), [JSON.encode!(entry), "\n"], [:append, :sync]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Couldn't write the watch history: #{:file.format_error(reason)}")
    end
  end

  defp compact(entries) do
    tmp = path() <> ".tmp"
    data = Enum.map(entries, &[JSON.encode!(&1), "\n"])

    with :ok <- File.write(tmp, data, [:sync]),
         :ok <- File.rename(tmp, path()) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Couldn't compact the watch history: #{:file.format_error(reason)}")
    end
  end

  defp index(entries),
    do: entries |> Enum.with_index() |> Map.new(fn {entry, at} -> {entry.id, at} end)

  defp id do
    "#{System.os_time(:millisecond)}-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"
  end
end
