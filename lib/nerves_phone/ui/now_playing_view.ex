defmodule NervesPhone.UI.NowPlayingView do
  @moduledoc """
  What's playing: cover art, the track, progress, and the controls:
  previous, play/pause and next. Shuffle is always on, so it's shown, not
  offered. The power button also plays/pauses and the volume buttons set
  the volume (shown in the title bar).
  """

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [event: 3]

  def toolbar(workspace) do
    [
      {:list, "Playlists", event(workspace, :show, :library), false},
      {:search, "Search", event(workspace, :show, :search), false},
      :separator,
      {:music, "Playing", event(workspace, :show, :now_playing), true}
    ]
  end

  def status(player) do
    case player.track do
      %{duration_ms: duration} -> "#{clock(player.progress_ms)} / #{clock(duration)}"
      _ -> "Nothing playing"
    end
  end

  def render(player) do
    el(
      [width(fill()), height(fill()), scrollbar_y()],
      column([width(fill()), padding(s(16)), spacing(s(14))], [
        el([width(px(s(320))), center_x()], cover(player.cover, 320)),
        track_info(player),
        progress_bar(player),
        controls(player),
        el([center_x()], shuffle_note()),
        if(player.error, do: error(player.error), else: none())
      ])
    )
  end

  defp track_info(%{track: %{} = track}) do
    column([width(fill()), spacing(s(4))], [
      paragraph([width(fill()), Font.size(s(20)), Font.semi_bold()], [text(track.name)]),
      paragraph([width(fill()), Font.size(s(14)), Font.color(c(:dim))], [text(track.artists)]),
      paragraph([width(fill()), Font.size(s(12)), Font.light(), Font.color(c(:faint))], [
        text(track.album)
      ])
    ])
  end

  defp track_info(player) do
    note =
      cond do
        player.pending -> "Starting…"
        not player.device_ready -> "Waiting for the phone to connect…"
        true -> "Nothing playing. Pick a playlist or search."
      end

    el([Font.size(s(16)), Font.light(), Font.color(c(:dim))], text(note))
  end

  defp progress_bar(%{track: %{duration_ms: duration}} = player) when duration > 0 do
    column([width(fill()), spacing(s(4))], [
      progress(player.progress_ms, duration),
      row([width(fill()), Font.size(s(11)), Font.light(), Font.color(c(:faint))], [
        el([width(fill())], text(clock(player.progress_ms))),
        text(clock(duration))
      ])
    ])
  end

  defp progress_bar(_player), do: none()

  defp controls(player) do
    row([center_x(), spacing(s(16))], [
      round_button(:previous, event(player, :previous, nil), 56, 22),
      round_button(
        if(player.is_playing, do: :pause, else: :play),
        event(player, :toggle_play, nil),
        76,
        30
      ),
      round_button(:next, event(player, :next, nil), 56, 22)
    ])
  end

  defp round_button(icon_name, on_press, size, icon_size) do
    Input.button(
      [
        width(px(s(size))),
        height(px(s(size))),
        center_y(),
        Border.rounded(s(div(size, 2))),
        Background.color(vgrad(:s4, :s5)),
        Event.on_press(on_press),
        Interactive.mouse_down([Background.color(vgrad(:s3, :s2))])
      ] ++ raised(),
      el([center_x(), center_y()], icon(icon_name, icon_size, c(:text)))
    )
  end

  defp shuffle_note do
    row(
      [
        padding_xy(s(10), s(6)),
        spacing(s(6)),
        Border.rounded(s(2)),
        Background.color(vgrad(:s2, :s3)),
        Font.size(s(11)),
        Font.medium(),
        Font.color(c(:dim)),
        Font.letter_spacing(0.5)
      ] ++ sunken(),
      [el([center_y()], icon(:shuffle, 14, c(:dim))), text("SHUFFLE · ALWAYS ON")]
    )
  end

  defp error(message) do
    paragraph([width(fill()), Font.size(s(12)), Font.color(c(:red))], [text(message)])
  end
end
