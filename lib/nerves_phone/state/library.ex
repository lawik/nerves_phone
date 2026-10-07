defmodule NervesPhone.State.Library do
  @moduledoc """
  Your playlists and the list filter (all, or only ones you own).

  On start the cached list (`NervesPhone.Music.Cache`) shows right away,
  then a fresh one is fetched in the background; it replaces the cached one,
  and is saved, only if something changed. `:refresh` fetches again. While
  the network isn't up yet, it keeps retrying.
  """

  use Solve.Controller, events: [:refresh, :set_filter]

  alias NervesPhone.Music.{Backend, Cache}

  @cache "playlists"

  @retry_ms 10_000

  @impl Solve.Controller
  def init(_params, _dependencies) do
    send(self(), :load)
    %{status: :loading, playlists: [], filter: :all}
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    visible =
      if state.filter == :mine, do: Enum.filter(state.playlists, & &1.mine), else: state.playlists

    %{
      status: state.status,
      filter: state.filter,
      playlists: state.playlists,
      visible: visible,
      by_id: Map.new(state.playlists, &{&1.id, &1})
    }
  end

  def refresh(_payload, state) do
    send(self(), :load)
    %{state | status: :loading}
  end

  def set_filter(filter, state) when filter in [:all, :mine], do: %{state | filter: filter}

  def handle_info(:load, state) do
    case Backend.impl().setup_hint() do
      nil ->
        controller = self()

        async(fn ->
          # What's on disk first, then what's current.
          if state.playlists == [], do: send(controller, {:cached, Cache.read(@cache)})
          send(controller, {:loaded, safely(fn -> Backend.impl().playlists() end)})
        end)

        %{state | status: if(state.playlists == [], do: :loading, else: state.status)}

      hint ->
        %{state | status: {:setup, hint}}
    end
  end

  def handle_info({:cached, {:ok, playlists}}, %{playlists: []} = state) when is_list(playlists),
    do: %{state | status: :ready, playlists: playlists}

  def handle_info({:cached, _}, state), do: state

  # Unchanged data leaves the state as it was, so nothing re-renders.
  def handle_info({:loaded, {:ok, playlists}}, state) do
    if playlists != state.playlists, do: async(fn -> Cache.write(@cache, playlists) end)
    %{state | status: :ready, playlists: playlists}
  end

  # Offline at boot, for example: keep what's cached and try again.
  def handle_info({:loaded, {:error, reason}}, state) do
    Process.send_after(self(), :load, @retry_ms)
    if state.playlists == [], do: %{state | status: {:error, reason}}, else: state
  end

  def handle_info(_message, state), do: state

  defp async(fun), do: Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fun)

  defp safely(fun) do
    fun.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
