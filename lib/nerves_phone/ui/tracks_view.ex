defmodule NervesPhone.UI.TracksView do
  @moduledoc """
  An open playlist or album: its tracks in a scrolling list. "Shuffle play"
  plays it from a random track; tapping a track plays it from there (still
  shuffled).

  Tracks arrive page by page while the list is already usable; every
  track gets a row.
  """

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [event: 3]

  def toolbar(context, workspace, player) do
    [
      {:list, "Playlists", event(workspace, :show, :library), false},
      {:search, "Search", event(workspace, :show, :search), false},
      :separator,
      {:shuffle, "Shuffle",
       event(player, :play_context, %{uri: context.uri, total: context.total}), false}
    ]
  end

  def status(context) do
    count = length(context.tracks)

    case context.status do
      :loading -> "Loading tracks…"
      :loading_more -> "#{count} of #{context.total} tracks…"
      :not_listable -> context.name
      {:error, _} -> "Couldn't load tracks"
      :ready -> "#{context.name} · #{count} tracks"
    end
  end

  def render(context, workspace, player) do
    column([width(fill()), height(fill())], [
      header(context, player),
      body(context, workspace, player)
    ])
  end

  defp header(context, player) do
    row(
      [
        width(fill()),
        padding_xy(s(12), s(10)),
        spacing(s(10)),
        Background.color(vgrad(:s1, :s2)),
        Border.width_each(0, 0, 1, 0),
        Border.color(c(:text, 0.06))
      ],
      [
        column([width(fill()), spacing(s(2))], [
          paragraph([width(fill()), Font.size(s(17)), Font.semi_bold()], [text(context.name)]),
          el(
            [Font.size(s(12)), Font.light(), Font.color(c(:dim))],
            text("#{context.subtitle} · #{context.total} tracks")
          )
        ]),
        button(
          [icon(:shuffle, 16, c(:text)), text("Shuffle play")],
          event(player, :play_context, %{uri: context.uri, total: context.total}),
          primary: true
        )
      ]
    )
  end

  defp body(%{status: :loading}, _workspace, _player), do: message(["Loading tracks…"])

  defp body(%{status: :not_listable}, _workspace, _player) do
    message([
      "The music service only lists the tracks of your own playlists.",
      "Shuffle play still plays it."
    ])
  end

  defp body(%{status: {:error, reason}, tracks: []}, _workspace, _player),
    do: message(["Couldn't load the tracks.", describe_error(reason)])

  defp body(context, _workspace, player) do
    playing_uri = player.track && player.track.uri
    in_context? = player.context_uri == context.uri

    scroll_list(
      for {track, i} <- Enum.with_index(context.tracks, 1) do
        list_row(
          {:track, i},
          event(player, :play_track, %{context_uri: context.uri, track_uri: track.uri}),
          track.name,
          track_meta(track, context.kind),
          clock(track.duration_ms),
          in_context? and track.uri == playing_uri
        )
      end
    )
  end

  defp track_meta(track, :album), do: track.artists

  defp track_meta(track, _kind),
    do: Enum.join(Enum.reject([track.artists, track.album], &(&1 == "")), " · ")
end
