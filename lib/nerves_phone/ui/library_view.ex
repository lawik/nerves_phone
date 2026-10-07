defmodule NervesPhone.UI.LibraryView do
  @moduledoc """
  Your playlists, all in one scrolling list. Tapping one opens it.

  Rows are text only and keyed, so a long library diffs cheaply; the list
  isn't re-rendered while only playback progress changes (see
  `NervesPhone.UI`).
  """

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [event: 3]

  def toolbar(library, workspace) do
    [
      {:list, "All", event(library, :set_filter, :all), library.filter == :all},
      {:user, "Mine", event(library, :set_filter, :mine), library.filter == :mine},
      :separator,
      {:search, "Search", event(workspace, :show, :search), false},
      {:refresh, "Refresh", event(library, :refresh, nil), false}
    ]
  end

  def status(library) do
    case library.status do
      :ready -> "#{length(library.visible)} playlists"
      :loading -> "Loading playlists…"
      {:setup, _} -> "Not set up"
      {:error, _} -> "Couldn't load playlists"
    end
  end

  def render(%{status: {:setup, hint}}, _workspace, _player), do: message([hint])

  def render(%{status: :loading, playlists: []}, _workspace, _player),
    do: message(["Loading playlists…"])

  def render(%{status: {:error, reason}, playlists: []}, _workspace, _player),
    do:
      message(["Couldn't load your playlists.", describe_error(reason), "Trying again shortly."])

  def render(%{visible: []}, _workspace, _player), do: message(["No playlists here."])

  def render(library, workspace, player) do
    scroll_list(
      for playlist <- library.visible do
        list_row(
          {:playlist, playlist.id},
          event(workspace, :open_playlist, playlist.id),
          playlist.name,
          playlist_meta(playlist),
          "#{playlist.total}",
          playlist.uri == player.context_uri
        )
      end
    )
  end

  def playlist_meta(playlist),
    do: if(playlist.mine, do: "Yours", else: "By #{playlist.owner}")
end
