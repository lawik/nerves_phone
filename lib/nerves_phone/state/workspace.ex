defmodule NervesPhone.State.Workspace do
  @moduledoc """
  What's open and what's on screen: the dock, each open playlist's or
  album's tracks, and search.

  The dock always starts with the playlists. Search and "Playing" get a chip
  once used, and each playlist or album you open gets one that can be
  closed. The active chip is what's on screen.

  Track lists come from the cache (`NervesPhone.Music.Cache`) when they're
  there, and are fetched again in the background, page by page (50 tracks a
  request); the fresh list replaces the cached one, and is saved, only if it
  differs. Without a cache, tracks show page by page as they arrive. Search
  runs a moment after typing stops, and only the latest query's results are
  kept.
  """

  use Solve.Controller,
    events: [
      :open_playlist,
      :open_album,
      :show,
      :close,
      :query_changed,
      :search_now
    ]

  alias NervesPhone.Music.{Backend, Cache}

  # Stop loading a playlist past this many tracks.
  @max_tracks 5_000
  @search_delay_ms 400

  @impl Solve.Controller
  def init(_params, _dependencies) do
    %{
      open: [],
      active: :library,
      search_open: false,
      contexts: %{},
      search: %{query: "", status: :idle, results: nil, generation: 0}
    }
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{
      active: state.active,
      search_open: state.search_open,
      open: Enum.map(state.open, &Map.fetch!(state.contexts, &1)),
      context: if(is_tuple(state.active), do: state.contexts[state.active]),
      search: state.search
    }
  end

  # From the library by id, or a playlist found by search.
  def open_playlist(%{id: _} = p, state, _deps), do: open_playlist_meta(state, p)

  def open_playlist(id, state, %{library: %{by_id: by_id}}) do
    case by_id[id] do
      nil -> state
      p -> open_playlist_meta(state, p)
    end
  end

  defp open_playlist_meta(state, p) do
    open(state, {:playlist, p.id}, %{
      kind: :playlist,
      id: p.id,
      uri: p.uri,
      name: p.name,
      subtitle: if(p.mine, do: "Your playlist", else: "By #{p.owner}"),
      total: p.total
    })
  end

  def open_album(album, state, _deps) when is_map(album) do
    open(state, {:album, album.id}, %{
      kind: :album,
      id: album.id,
      uri: album.uri,
      name: album.name,
      subtitle: Enum.join(Enum.reject([album.artists, album.year], &(&1 in [nil, ""])), " · "),
      total: album.total
    })
  end

  def show(target, state, _deps) do
    cond do
      target in [:library, :now_playing] -> %{state | active: target}
      target == :search -> %{state | active: :search, search_open: true}
      Map.has_key?(state.contexts, target) -> %{state | active: target}
      true -> state
    end
  end

  def close(:search, state, _deps) do
    %{
      state
      | search_open: false,
        active: if(state.active == :search, do: :library, else: state.active)
    }
  end

  def close(key, state, _deps) do
    %{
      state
      | open: List.delete(state.open, key),
        contexts: Map.delete(state.contexts, key),
        active: if(state.active == key, do: :library, else: state.active)
    }
  end

  # Typing: wait for a pause before searching.
  def query_changed(query, state, _deps) when is_binary(query) do
    generation = state.search.generation + 1
    Process.send_after(self(), {:search, generation}, @search_delay_ms)
    %{state | search: %{state.search | query: query, generation: generation}}
  end

  def search_now(_payload, state, _deps) do
    generation = state.search.generation + 1
    send(self(), {:search, generation})
    %{state | search: %{state.search | generation: generation}}
  end

  def handle_info({:search, generation}, %{search: %{generation: generation}} = state) do
    query = String.trim(state.search.query)

    if query == "" do
      %{state | search: %{state.search | status: :idle, results: nil}}
    else
      controller = self()

      async(fn ->
        send(controller, {:searched, generation, safely(fn -> Backend.impl().search(query) end)})
      end)

      %{state | search: %{state.search | status: :searching}}
    end
  end

  def handle_info({:search, _stale}, state), do: state

  def handle_info({:searched, generation, result}, %{search: %{generation: generation}} = state) do
    search =
      case result do
        {:ok, results} -> %{state.search | status: :ready, results: results}
        {:error, reason} -> %{state.search | status: {:error, reason}}
      end

    %{state | search: search}
  end

  def handle_info({:searched, _stale, _result}, state), do: state

  # The cached list, if there is one, until the fresh one is complete.
  def handle_info({:cached_tracks, key, {:ok, tracks}}, state) when is_list(tracks) do
    case state.contexts[key] do
      %{loaded: loaded} = context
      when loaded != :done and length(tracks) >= length(context.tracks) ->
        put_context(state, key, %{context | tracks: tracks, cached: true, status: :ready})

      _ ->
        state
    end
  end

  def handle_info({:cached_tracks, _key, _miss}, state), do: state

  # A page of tracks arrived: collect it and fetch the next one. Without a
  # cached list, show the tracks so far.
  def handle_info({:tracks, key, offset, result}, state) do
    case {state.contexts[key], result} do
      {nil, _} ->
        state

      {%{loaded: ^offset} = context, {:ok, page}} ->
        fresh = context.fresh ++ page.items
        next = if page.next && length(fresh) < @max_tracks, do: page.next
        total = max(context.total, page.total)

        if next do
          fetch(key, context, next)
          shown = if context.cached, do: context.tracks, else: fresh
          status = if context.cached, do: :ready, else: :loading_more

          put_context(state, key, %{
            context
            | fresh: fresh,
              loaded: next,
              tracks: shown,
              status: status,
              total: total
          })
        else
          # Complete: replace and save only when it changed.
          if fresh != context.tracks or not context.cached,
            do: async(fn -> Cache.write(cache_name(context), fresh) end)

          put_context(state, key, %{
            context
            | fresh: [],
              loaded: :done,
              tracks: fresh,
              status: :ready,
              total: total
          })
        end

      {context, {:error, :not_listable}} ->
        put_context(state, key, %{context | status: :not_listable, loaded: :done})

      # Offline, say: a cached list stays usable.
      {%{cached: true} = context, {:error, _reason}} ->
        put_context(state, key, %{context | status: :ready, loaded: :done, fresh: []})

      {context, {:error, reason}} ->
        put_context(state, key, %{context | status: {:error, reason}, loaded: :done})

      _stale ->
        state
    end
  end

  def handle_info(_message, state), do: state

  defp open(state, key, meta) do
    if Map.has_key?(state.contexts, key) do
      %{state | active: key}
    else
      context =
        Map.merge(meta, %{
          key: key,
          status: :loading,
          tracks: [],
          fresh: [],
          loaded: 0,
          cached: false
        })

      controller = self()
      async(fn -> send(controller, {:cached_tracks, key, Cache.read(cache_name(context))}) end)
      fetch(key, context, 0)

      %{
        state
        | open: state.open ++ [key],
          active: key,
          contexts: Map.put(state.contexts, key, context)
      }
    end
  end

  defp fetch(key, context, offset) do
    controller = self()
    kind = context.kind
    id = context.id

    async(fn ->
      result = safely(fn -> Backend.impl().tracks(kind, id, offset) end)
      send(controller, {:tracks, key, offset, result})
    end)
  end

  defp cache_name(context), do: "tracks/#{context.kind}-#{context.id}"

  defp put_context(state, key, context),
    do: %{state | contexts: Map.put(state.contexts, key, context)}

  defp async(fun), do: Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fun)

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
