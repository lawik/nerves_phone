defmodule NervesPhone.UI.SearchView do
  @moduledoc """
  Search: a text field, an on-screen keyboard, and results in three groups.

    * Songs play their album from that song (shuffled).
    * Albums and playlists open like your own playlists do.

  The keyboard's keys are Emerge virtual keys, which type into the focused
  field; the field reports changes to `:workspace`, which searches once
  typing pauses.
  """

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [event: 2, event: 3]

  @rows [~w(q w e r t y u i o p), ~w(a s d f g h j k l), ~w(z x c v b n m)]

  def toolbar(workspace) do
    [
      {:list, "Playlists", event(workspace, :show, :library), false},
      {:search, "Search", event(workspace, :show, :search), true},
      :separator,
      {:close, "Close", event(workspace, :close, :search), false}
    ]
  end

  def status(%{search: search}) do
    case search.status do
      :idle -> "Search songs, albums and playlists"
      :searching -> "Searching for “#{search.query}”…"
      :ready -> "Results for “#{search.query}”"
      {:error, _} -> "Search failed"
    end
  end

  def render(workspace, player) do
    column([width(fill()), height(fill())], [
      field(workspace),
      el([width(fill()), height(fill())], results(workspace, player)),
      keyboard(workspace)
    ])
  end

  defp field(workspace) do
    row(
      [
        width(fill()),
        padding(s(8)),
        spacing(s(8)),
        Background.color(vgrad(:s4, :s5))
      ],
      [
        el(
          [
            width(fill()),
            padding_xy(s(10), s(8)),
            Border.rounded(s(2)),
            Background.color(c(:s0))
          ] ++ sunken(),
          row([width(fill()), spacing(s(8))], [
            el([key(:search_icon), center_y()], icon(:search, 16, c(:dim))),
            Input.text(
              [
                key(:search),
                focus_on_mount(),
                width(fill()),
                Font.size(s(15)),
                Event.on_change(event(workspace, :query_changed)),
                Event.on_key_down(:enter, event(workspace, :search_now))
              ],
              workspace.search.query
            )
          ])
        )
      ]
    )
  end

  defp results(%{search: %{status: :idle}}, _player),
    do: message(["Type to search.", "Songs, albums and playlists, nothing fancy."])

  defp results(%{search: %{status: :searching, results: nil}}, _player),
    do: message(["Searching…"])

  defp results(%{search: %{status: {:error, reason}}}, _player),
    do: message(["Search failed.", describe_error(reason)])

  defp results(%{search: %{results: results}} = workspace, player) do
    playing_uri = player.track && player.track.uri

    songs =
      for t <- results.tracks do
        list_row(
          {:song, t.id},
          event(player, :play_track, %{context_uri: t.album_uri, track_uri: t.uri}),
          t.name,
          "#{t.artists} · #{t.album}",
          clock(t.duration_ms),
          t.uri == playing_uri
        )
      end

    albums =
      for a <- results.albums do
        list_row(
          {:album, a.id},
          event(workspace, :open_album, a),
          a.name,
          Enum.join(Enum.reject([a.artists, a.year], &(&1 in [nil, ""])), " · "),
          "#{a.total}"
        )
      end

    playlists =
      for p <- results.playlists do
        list_row(
          {:found_playlist, p.id},
          event(workspace, :open_playlist, p),
          p.name,
          "By #{p.owner}",
          "#{p.total}"
        )
      end

    sections =
      [{"Songs", songs}, {"Albums", albums}, {"Playlists", playlists}]
      |> Enum.reject(fn {_, rows} -> rows == [] end)
      |> Enum.flat_map(fn {title, rows} -> [section(title) | rows] end)

    if sections == [], do: message(["Nothing found."]), else: scroll_list(sections)
  end

  # Keyed like the rows around it: Emerge wants all siblings keyed or none.
  defp section(title) do
    el(
      [key({:section, title}), width(fill()), padding_each(s(12), s(12), s(4), s(12))],
      label(title)
    )
  end

  defp keyboard(_workspace) do
    letter_rows =
      for keys <- @rows do
        row([center_x(), spacing(s(4))], Enum.map(keys, &key_button(&1, {:text, &1}, 36)))
      end

    bottom =
      row([center_x(), spacing(s(4))], [
        key_button(icon(:backspace, 18, c(:text)), {:key, :backspace, []}, 64, repeat: true),
        key_button("space", {:text, " "}, 200),
        key_button(icon(:search, 18, c(:text)), {:key, :enter, []}, 64)
      ])

    column(
      [
        width(fill()),
        padding(s(6)),
        spacing(s(6)),
        Background.color(vgrad(:s5, :s4)),
        Border.width_each(1, 0, 0, 0),
        Border.color(c(:text, 0.08))
      ],
      letter_rows ++ [bottom]
    )
  end

  defp key_button(label, tap, width, opts \\ []) do
    Input.button(
      [
        width(px(s(width))),
        height(px(s(44))),
        Border.rounded(s(3)),
        Background.color(vgrad(:s0, :s1)),
        Font.size(s(16)),
        Event.virtual_key(tap: tap, hold: if(opts[:repeat], do: :repeat)),
        Interactive.mouse_down([Background.color(vgrad(:s3, :s2))])
      ] ++ raised(),
      el([center_x(), center_y()], if(is_binary(label), do: text(label), else: label))
    )
  end
end
