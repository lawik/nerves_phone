defmodule NervesPhone.Music.Covers do
  @moduledoc """
  Cover art, downloaded on demand and cached on disk.

  Scheme:

    * Files live in `state_dir/covers` (`/data/music/covers` on the
      phone), named by a hash of the image URL. Spotify's image URLs are
      content-addressed, so a cached file never goes stale.
    * An ETS table indexes what's on disk, so `path/1` is a cheap lookup
      that never touches the filesystem from a render. Files from earlier
      boots are indexed the first time they're asked for.
    * Downloads run one at a time. `want/2` replaces the queue with what's
      visible now, so scrolling past a page drops its pending covers instead
      of piling up requests. A URL that's queued or downloading is never
      fetched twice.
    * Whoever asked gets `{:cover_ready, url}` when a file lands.
    * At start the cache is trimmed to the newest #{500} files.
  """

  use GenServer
  require Logger

  @table __MODULE__
  @max_files 500

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The directory covers are saved in; the viewport allowlists it."
  def dir, do: Path.join(NervesPhone.Music.state_dir(), "covers")

  @doc "The local path for `url` if it's cached, or nil. Never blocks."
  def path(nil), do: nil

  def path(url) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, url) do
      [{^url, path}] -> path
      _ -> nil
    end
  end

  @doc """
  Asks for these covers, in priority order, replacing what this caller
  asked for before. The caller gets `{:cover_ready, url}` for each one that
  downloads.
  """
  def want(urls, pid \\ self()) do
    GenServer.cast(__MODULE__, {:want, pid, Enum.reject(urls, &(&1 == nil))})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    File.mkdir_p!(dir())
    index_and_trim()
    {:ok, %{queue: [], wanted_by: %{}, downloading: nil}}
  end

  @impl GenServer
  def handle_cast({:want, pid, urls}, state) do
    # Files from a previous boot get indexed on first request.
    {cached, urls} = Enum.split_with(urls, &cached?/1)
    for url <- cached, do: send(pid, {:cover_ready, url})
    urls = Enum.reject(urls, &downloading?(state, &1))

    # This caller's previous requests are replaced; other callers' stay.
    wanted_by =
      state.wanted_by
      |> Map.new(fn {url, pids} -> {url, MapSet.delete(pids, pid)} end)
      |> Map.reject(fn {url, pids} -> MapSet.size(pids) == 0 and not downloading?(state, url) end)

    wanted_by =
      Enum.reduce(urls, wanted_by, fn url, acc ->
        Map.update(acc, url, MapSet.new([pid]), &MapSet.put(&1, pid))
      end)

    # The newest request goes first; keep what other callers still want.
    rest = Enum.filter(state.queue, &(Map.has_key?(wanted_by, &1) and &1 not in urls))
    {:noreply, next(%{state | queue: urls ++ rest, wanted_by: wanted_by})}
  end

  @impl GenServer
  def handle_info({ref, result}, %{downloading: {url, ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, file} ->
        :ets.insert(@table, {url, file})
        for pid <- Map.get(state.wanted_by, url, []), do: send(pid, {:cover_ready, url})

      {:error, reason} ->
        Logger.debug("[covers] #{url} failed: #{inspect(reason)}")
    end

    state = %{state | downloading: nil, wanted_by: Map.delete(state.wanted_by, url)}
    {:noreply, next(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{downloading: {url, ref}} = state) do
    state = %{state | downloading: nil, wanted_by: Map.delete(state.wanted_by, url)}
    {:noreply, next(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp downloading?(%{downloading: {url, _ref}}, url), do: true
  defp downloading?(_state, _url), do: false

  defp cached?(url) do
    cond do
      path(url) ->
        true

      File.exists?(file(url)) ->
        :ets.insert(@table, {url, file(url)})
        true

      true ->
        false
    end
  end

  defp next(%{downloading: nil, queue: [url | rest]} = state) do
    task = Task.Supervisor.async_nolink(NervesPhone.TaskSupervisor, fn -> download(url) end)
    %{state | downloading: {url, task.ref}, queue: rest}
  end

  defp next(state), do: state

  defp download(url) do
    file = file(url)

    case Req.get(url, retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        tmp = file <> ".part"
        File.write!(tmp, body)
        File.rename!(tmp, file)
        {:ok, file}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # File names are hashes, so the index fills in lazily as covers are
  # requested (see cached?/1). Here only the newest files are kept.
  defp index_and_trim do
    files =
      Path.wildcard(Path.join(dir(), "*.jpg"))
      |> Enum.map(&{&1, File.stat!(&1, time: :posix).mtime})
      |> Enum.sort_by(&elem(&1, 1), :desc)

    {_keep, drop} = Enum.split(files, @max_files)
    Enum.each(drop, fn {file, _} -> File.rm(file) end)
    Path.wildcard(Path.join(dir(), "*.part")) |> Enum.each(&File.rm/1)
  end

  defp file(url) do
    name = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> binary_part(0, 32)
    Path.join(dir(), name <> ".jpg")
  end
end
