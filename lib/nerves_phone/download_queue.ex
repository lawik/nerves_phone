defmodule NervesPhone.DownloadQueue do
  @moduledoc """
  Things to download, done one at a time, in order, and kept in
  `state_dir/download_queue.json` so the queue carries on after a
  restart (a download that was running starts again).

  phone_remote queues things here (search results from
  `NervesPhone.Search`, an SVT programme's episodes, or a pasted link)
  and follows it through the `:download_queue` controller of
  `NervesPhone.State`.

  YouTube and the other sites yt-dlp knows go to `NervesPhone.YtDlp`,
  SVT Play and UR Play to `NervesPhone.SvtPlay`; both download only what
  the phone plays. Where files go is `config :nerves_phone,
  :download_queue, youtube_dir: ..., svt_dir: ..., svt_resolution: ...`
  (by default `youtube` and `svtplay` in `NervesPhone.state_dir/0`, at
  most 720 lines). `run: false` there keeps everything waiting, for
  tests.

  Changes are sent to subscribers (`subscribe/0`) as
  `{NervesPhone.DownloadQueue, items}`.
  """

  use GenServer

  require Logger

  alias NervesPhone.SvtPlay.Catalog
  alias NervesPhone.Video.Metadata
  alias NervesPhone.{SvtPlay, YtDlp}

  @typedoc """
  `mode` is `:video` or `:audio` for yt-dlp, and `:one` (the episode, or
  a programme's newest) or `:all_episodes` (UR Play's; SVT Play's are
  queued one by one) for svtplay-dl. `label` names where it's from.
  `kind` is how the downloaded videos are sorted (see
  `NervesPhone.Video.Metadata`).
  """
  @type item :: %{
          id: pos_integer(),
          source: :youtube | :svt,
          label: String.t(),
          title: String.t(),
          subtitle: String.t() | nil,
          thumbnail: String.t() | nil,
          url: String.t(),
          mode: :video | :audio | :one | :all_episodes,
          kind: String.t() | nil,
          status: :queued | :downloading | :done | :failed | :cancelled,
          progress: float() | nil,
          message: String.t() | nil,
          paths: [String.t()]
        }

  @modes %{youtube: [:video, :audio], svt: [:one, :all_episodes]}
  @statuses [:queued, :downloading, :done, :failed, :cancelled]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Sends the caller `{NervesPhone.DownloadQueue, items}` now and on every
  change, for as long as it lives.
  """
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @spec items() :: [item()]
  def items, do: GenServer.call(__MODULE__, :items)

  @doc """
  Queues a search result (`t:NervesPhone.Search.result/0`, or anything
  with its `source`, `title`, `url` and maybe `subtitle`, `thumbnail`
  and `label`).
  """
  @spec add(map(), :video | :audio | :one | :all_episodes, String.t() | nil) ::
          :ok | {:error, String.t()}
  def add(result, mode, kind \\ nil) do
    with :ok <- check(result.source, mode, kind) do
      GenServer.call(__MODULE__, {:add, [to_item(result, mode, kind)]})
    end
  end

  @doc """
  Queues every downloadable episode of an SVT Play programme that isn't
  queued already, one by one, rather than svtplay-dl's `--all-episodes`,
  which would try copy-protected and unpublished ones too. Returns how
  many it queued.
  """
  @spec add_all_episodes(String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def add_all_episodes(programme, kind \\ nil) do
    with :ok <- check(:svt, :one, kind),
         {:ok, sections} <- Catalog.episodes(programme) do
      waiting = for %{status: s, url: url} <- items(), s in [:queued, :downloading], do: url

      episodes =
        sections
        |> Enum.flat_map(& &1.episodes)
        |> Enum.uniq_by(& &1.url)
        |> Enum.reject(&(&1.url in waiting))

      :ok = GenServer.call(__MODULE__, {:add, Enum.map(episodes, &to_item(&1, :one, kind))})
      {:ok, length(episodes)}
    end
  end

  @doc """
  Queues a link, as `as` (`"video"`, `"audio"` or `"all_episodes"`).
  svtplay-dl takes SVT Play and UR Play; anything else goes to yt-dlp,
  which knows YouTube and many other sites. Returns how many it queued
  (more than one for all of an SVT Play programme's episodes).
  """
  @spec add_url(String.t(), String.t(), String.t() | nil) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def add_url(url, as, kind \\ nil) do
    url = String.trim(url)
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] or uri.host in [nil, ""] ->
        {:error, "Paste a web address, starting with https://"}

      # SVT Play's episodes are listed, so only downloadable ones are
      # queued; UR Play's are left to svtplay-dl.
      as == "all_episodes" and svt?(uri.host) ->
        add_all_episodes(url, kind)

      svtplay_dl?(uri.host) ->
        mode = if as == "all_episodes", do: :all_episodes, else: :one
        with :ok <- add(link(url, :svt, uri.host), mode, kind), do: {:ok, 1}

      as == "all_episodes" ->
        {:error, "All episodes is for SVT Play and UR Play links"}

      true ->
        mode = if as == "audio", do: :audio, else: :video
        with :ok <- add(link(url, :youtube, uri.host), mode, kind), do: {:ok, 1}
    end
  end

  @doc """
  Removes a queued or finished item, or cancels the one downloading (a
  YouTube download; svtplay-dl can't be stopped).
  """
  @spec remove(pos_integer()) :: :ok
  def remove(id), do: GenServer.call(__MODULE__, {:remove, id})

  @doc "Queues a failed or cancelled item again."
  @spec retry(pos_integer()) :: :ok
  def retry(id), do: GenServer.call(__MODULE__, {:retry, id})

  @doc "Removes everything that's finished, one way or another."
  @spec clear_finished() :: :ok
  def clear_finished, do: GenServer.call(__MODULE__, :clear_finished)

  defp check(source, mode, kind) do
    cond do
      mode not in Map.get(@modes, source, []) -> {:error, "Can't download #{source} as #{mode}"}
      kind not in [nil | Metadata.kinds()] -> {:error, "There's no kind #{inspect(kind)}"}
      true -> :ok
    end
  end

  defp to_item(result, mode, kind) do
    %{
      id: nil,
      source: result.source,
      label: Map.get(result, :label) || default_label(result.source),
      title: result.title,
      subtitle: Map.get(result, :subtitle),
      thumbnail: Map.get(result, :thumbnail),
      url: result.url,
      mode: mode,
      kind: kind,
      status: :queued,
      progress: nil,
      message: nil,
      paths: []
    }
  end

  defp link(url, source, host), do: %{source: source, label: site(host), title: url, url: url}

  defp svt?(host), do: domain?(host, "svtplay.se") or domain?(host, "svt.se")
  defp svtplay_dl?(host), do: svt?(host) or domain?(host, "urplay.se")

  defp site(host) do
    cond do
      svt?(host) -> "SVT Play"
      domain?(host, "urplay.se") -> "UR Play"
      domain?(host, "youtube.com") or domain?(host, "youtu.be") -> "YouTube"
      true -> String.replace_prefix(host, "www.", "")
    end
  end

  defp domain?(host, domain), do: host == domain or String.ends_with?(host, "." <> domain)

  defp default_label(:youtube), do: "YouTube"
  defp default_label(:svt), do: "SVT Play"

  # ---------- Server ----------

  # active is the item downloading: {id, {:youtube, ref}} or
  # {id, {:svt, task}}.
  @impl GenServer
  def init(_opts) do
    items = load()
    next_id = Enum.reduce(items, 0, &max(&1.id, &2)) + 1
    :ok = NervesPhone.Downloads.subscribe()
    send(self(), :next)
    {:ok, %{items: items, next_id: next_id, active: nil, subscribers: %{}}}
  end

  @impl GenServer
  def handle_call(:items, _from, state), do: {:reply, state.items, state}

  def handle_call({:subscribe, pid}, _from, state) do
    send(pid, {__MODULE__, state.items})
    monitor = Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[pid], monitor)}
  end

  def handle_call({:add, new}, _from, state) do
    {new, next_id} =
      Enum.map_reduce(new, state.next_id, fn item, id -> {%{item | id: id}, id + 1} end)

    state = %{state | items: state.items ++ new, next_id: next_id}
    {:reply, :ok, state |> start_next() |> changed()}
  end

  def handle_call({:remove, id}, _from, state) do
    state =
      case state.active do
        {^id, {:youtube, ref}} ->
          YtDlp.cancel(ref)
          state

        {^id, {:svt, _task}} ->
          state

        _other ->
          %{state | items: Enum.reject(state.items, &(&1.id == id))}
      end

    {:reply, :ok, changed(state)}
  end

  def handle_call({:retry, id}, _from, state) do
    state =
      update(state, id, fn
        %{status: status} = item when status in [:failed, :cancelled] ->
          %{item | status: :queued, progress: nil, message: nil}

        item ->
          item
      end)

    {:reply, :ok, state |> start_next() |> changed()}
  end

  def handle_call(:clear_finished, _from, state) do
    items = Enum.filter(state.items, &(&1.status in [:queued, :downloading]))
    {:reply, :ok, changed(%{state | items: items})}
  end

  @impl GenServer
  def handle_info(:next, state), do: {:noreply, state |> start_next() |> changed()}

  def handle_info({YtDlp, ref, event}, %{active: {id, {:youtube, ref}}} = state) do
    state =
      case event do
        {:progress, downloaded, total} ->
          fraction = if is_integer(total) and total > 0, do: downloaded / total
          update(state, id, &%{&1 | progress: fraction})

        {:done, path} ->
          finish(state, id, :done, nil, [path])

        {:error, "cancelled"} ->
          finish(state, id, :cancelled, nil, [])

        {:error, message} ->
          finish(state, id, :failed, message, [])
      end

    {:noreply, changed(state, match?({:progress, _, _}, event))}
  end

  def handle_info({ref, result}, %{active: {id, {:svt, %Task{ref: ref}}}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, paths} -> finish(state, id, :done, nil, paths)
        {:error, message} -> finish(state, id, :failed, message, [])
      end

    {:noreply, changed(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{active: {id, {:svt, %Task{ref: ref}}}} = state
      ) do
    message = "svtplay-dl crashed: #{inspect(reason)}"
    {:noreply, state |> finish(id, :failed, message, []) |> changed()}
  end

  # svtplay-dl's progress only goes to NervesPhone.Downloads, as the
  # oldest download's, which is this one, as they're one at a time.
  def handle_info(
        {NervesPhone.Downloads, %{percent: percent}},
        %{active: {id, {:svt, _}}} = state
      )
      when is_integer(percent) do
    {:noreply, state |> update(id, &%{&1 | progress: percent / 100}) |> changed(true)}
  end

  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case state.subscribers do
      %{^pid => ^monitor} ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, id, status, message, paths) do
    state
    |> update(id, &%{&1 | status: status, message: message, paths: paths, progress: nil})
    |> Map.put(:active, nil)
    |> start_next()
  end

  defp start_next(%{active: nil} = state) do
    run? = Application.get_env(:nerves_phone, :download_queue, [])[:run] != false

    case run? && Enum.find(state.items, &(&1.status == :queued)) do
      falsy when falsy in [nil, false] ->
        state

      item ->
        case start(item) do
          {:ok, job} ->
            %{state | active: {item.id, job}}
            |> update(item.id, &%{&1 | status: :downloading, progress: nil})

          {:error, message} ->
            state
            |> update(item.id, &%{&1 | status: :failed, message: message})
            |> start_next()
        end
    end
  end

  defp start_next(state), do: state

  defp start(%{source: :youtube} = item) do
    opts = [as: item.mode] ++ if(item.kind, do: [kind: item.kind], else: [])

    with {:ok, ref} <- YtDlp.download(item.url, config(:youtube_dir), opts),
         do: {:ok, {:youtube, ref}}
  end

  defp start(%{source: :svt} = item) do
    opts =
      [
        output_dir: config(:svt_dir),
        all_episodes: item.mode == :all_episodes,
        resolution: config(:svt_resolution)
      ] ++ if(item.kind, do: [kind: item.kind], else: [])

    task =
      Task.Supervisor.async_nolink(NervesPhone.TaskSupervisor, fn ->
        SvtPlay.download(item.url, opts)
      end)

    {:ok, {:svt, task}}
  end

  defp config(key) do
    config = Application.get_env(:nerves_phone, :download_queue, [])

    case key do
      :youtube_dir -> config[:youtube_dir] || Path.join(NervesPhone.state_dir(), "youtube")
      :svt_dir -> config[:svt_dir] || Path.join(NervesPhone.state_dir(), "svtplay")
      :svt_resolution -> config[:svt_resolution] || "<=720"
    end
  end

  defp update(state, id, fun) do
    %{state | items: Enum.map(state.items, &if(&1.id == id, do: fun.(&1), else: &1))}
  end

  # Tells the subscribers, and saves the queue unless only progress
  # changed.
  defp changed(state, progress_only? \\ false) do
    unless progress_only?, do: save(state.items)
    for pid <- Map.keys(state.subscribers), do: send(pid, {__MODULE__, state.items})
    state
  end

  # ---------- The file ----------

  defp path, do: Path.join(NervesPhone.state_dir(), "download_queue.json")

  defp save(items) do
    File.mkdir_p(Path.dirname(path()))
    tmp = path() <> ".tmp"
    json = JSON.encode!(Enum.map(items, &Map.drop(&1, [:progress])))

    with :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, path()) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Couldn't save the download queue: #{:file.format_error(reason)}")
    end
  end

  # Unknown or broken entries are left out. What was downloading is
  # queued again.
  defp load do
    with {:ok, json} <- File.read(path()),
         {:ok, entries} when is_list(entries) <- JSON.decode(json) do
      for entry <- entries, item = from_json(entry), item != nil do
        if item.status == :downloading, do: %{item | status: :queued}, else: item
      end
    else
      _none -> []
    end
  end

  defp from_json(%{"id" => id, "source" => source, "mode" => mode, "status" => status} = e)
       when is_integer(id) do
    with source when source in [:youtube, :svt] <- atom(source, [:youtube, :svt]),
         mode when mode != nil <- atom(mode, @modes[source]),
         status when status != nil <- atom(status, @statuses) do
      %{
        id: id,
        source: source,
        label: e["label"] || default_label(source),
        title: e["title"] || e["url"],
        subtitle: e["subtitle"],
        thumbnail: e["thumbnail"],
        url: e["url"],
        mode: mode,
        kind: e["kind"],
        status: status,
        progress: nil,
        message: e["message"],
        paths: e["paths"] || []
      }
    else
      _broken -> nil
    end
  end

  defp from_json(_broken), do: nil

  defp atom(string, atoms), do: Enum.find(atoms, &(Atom.to_string(&1) == string))
end
