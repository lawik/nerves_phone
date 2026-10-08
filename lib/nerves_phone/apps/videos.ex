defmodule NervesPhone.Apps.Videos do
  @moduledoc """
  Videos: plays the video files found in folders under `/data`.

    * **Library** - every MP4, QuickTime or raw H.264 file, grouped by
      folder. Tap one to play it; Rescan looks again.
    * **Playing** - the picture on the whole screen, with back, play/pause,
      stop and the time on top; they hide while it plays, and a tap shows
      them. The screen stays on while it plays.

  The playback itself is `NervesPhone.Video.Player`: hardware decoding,
  frames to the screen without copies, and the sound to the speaker.
  State is in `NervesPhone.Apps.Videos.State`.
  """

  @behaviour NervesPhone.App

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [solve: 2, event: 2, event: 3]

  @app NervesPhone.State

  @impl NervesPhone.App
  def name, do: "Videos"

  @impl NervesPhone.App
  def icon, do: :film

  @impl NervesPhone.App
  def tile, do: {{232, 92, 72}, {176, 40, 64}}

  @impl NervesPhone.App
  def controllers, do: [[name: :videos, module: NervesPhone.Apps.Videos.State]]

  @impl NervesPhone.App
  def opened, do: Solve.dispatch(@app, :videos, :opened, nil)

  @impl NervesPhone.App
  def fullscreen? do
    videos = solve(@app, :videos)
    videos.page == :player and videos.playback != nil
  end

  @impl NervesPhone.App
  def toolbar do
    videos = solve(@app, :videos)

    library = {:list, "Library", event(videos, :show, :library), videos.page == :library}

    case {videos.page, videos.playback} do
      {:player, %{status: status}} ->
        [
          library,
          :separator,
          if(status == :playing,
            do: {:pause, "Pause", event(videos, :toggle_pause, nil), false},
            else: {:play, "Play", event(videos, :toggle_pause, nil), false}
          ),
          {:stop, "Stop", event(videos, :stop, nil), false}
        ]

      {:library, playback} ->
        [library] ++
          if(playback,
            do: [{:film, "Playing", event(videos, :show, :player), false}],
            else: []
          ) ++ [:separator, {:refresh, "Rescan", event(videos, :rescan, nil), videos.scanning}]

      _ ->
        [library]
    end
  end

  @impl NervesPhone.App
  def status do
    videos = solve(@app, :videos)

    case {videos.page, videos.playback} do
      {:player, %{} = p} ->
        "#{p.name} · #{describe(p.status)} #{clock(p.position_ms)}"

      _ ->
        count = videos.folders |> Enum.map(fn {_, files} -> length(files) end) |> Enum.sum()
        if videos.scanning, do: "Looking for videos…", else: "#{count} videos"
    end
  end

  @impl NervesPhone.App
  def back do
    videos = solve(@app, :videos)
    if videos.page == :player, do: event(videos, :stop, nil)
  end

  @impl NervesPhone.App
  def render do
    videos = solve(@app, :videos)

    case {videos.page, videos.playback} do
      {:player, %{} = playback} -> player(videos, playback)
      _ -> library(videos)
    end
  end

  # ---------- Library ----------

  defp library(%{folders: [], scanning: true}), do: message(["Looking for videos…"])

  defp library(%{folders: []}) do
    message([
      "No videos found.",
      "Put MP4 or H.264 files in a folder under /data, then tap Rescan."
    ])
  end

  defp library(videos) do
    playing = videos.playback && videos.playback.path

    scroll_list(
      Enum.flat_map(videos.folders, fn {folder, files} ->
        [
          section(folder)
          | for file <- files do
              list_row(
                {:video, file.path},
                event(videos, :play, file.path),
                file.name,
                kind(file.name),
                NervesPhone.DeviceInfo.size(file.size),
                file.path == playing
              )
            end
        ]
      end)
    )
  end

  defp kind(name) do
    case name |> Path.extname() |> String.downcase() do
      ext when ext in ~w(.h264 .264) -> "H.264, no sound"
      ".mov" -> "QuickTime"
      _ -> "MP4"
    end
  end

  # ---------- Playing ----------

  # The video edge to edge on black. Controls sit on top: back and the
  # title above, play/pause, stop and the time below. A tap on the video
  # shows or hides them.
  defp player(videos, playback) do
    message =
      case playback.status do
        :starting -> overlay_text("Starting…")
        :ended -> overlay_text("Finished")
        {:error, reason} -> overlay_text("Couldn't play this video: #{describe_error(reason)}")
        _ -> none()
      end

    controls =
      if videos.controls or playback.status != :playing,
        do: controls(videos, playback),
        else: none()

    Input.button(
      [
        width(fill()),
        height(fill()),
        Background.color(color_rgb(0, 0, 0)),
        Event.on_press(event(videos, :toggle_controls, nil)),
        Nearby.in_front(message),
        Nearby.in_front(controls)
      ],
      # A new target for each video, so the last one's frame never shows.
      video(
        [key({:video, playback.target}), width(fill()), height(fill()), image_fit(:contain)],
        playback.target
      )
    )
  end

  defp controls(videos, playback) do
    shade = fn angle ->
      Background.color(gradient([color_rgba(0, 0, 0, 0.75), color_rgba(0, 0, 0, 0.0)], angle))
    end

    top =
      row([width(fill()), padding_xy(s(8), s(10)), spacing(s(8)), shade.(270)], [
        overlay_button(:back, event(videos, :stop, nil)),
        el(
          [center_y(), width(fill()), Font.size(s(15)), Font.medium(), Font.color(c(:white))],
          text(playback.name)
        )
      ])

    playing? = playback.status == :playing

    buttons =
      row([width(fill()), spacing(s(14))], [
        overlay_button(
          if(playing?, do: :pause, else: :play),
          event(videos, :toggle_pause, nil),
          56
        ),
        overlay_button(:stop, event(videos, :stop, nil))
      ])

    bottom =
      column(
        [width(fill()), padding_each(s(24), s(12), s(14), s(12)), spacing(s(10)), shade.(90)],
        [scrubber(videos, playback), buttons]
      )

    column([width(fill()), height(fill())], [
      top,
      el([width(fill()), height(fill())], none()),
      bottom
    ])
  end

  # The progress bar, which seeks when dragged, with the time and the
  # length either side. A file without an index (raw H.264) has no length,
  # so only the time shows.
  defp scrubber(_videos, %{duration_ms: nil} = playback) do
    el(
      [Font.size(s(13)), Font.color(color_rgba(255, 255, 255, 0.9))],
      text(clock(playback.position_ms))
    )
  end

  defp scrubber(videos, playback) do
    duration = Kernel.max(playback.duration_ms, 1)
    position = Kernel.min(playback.position_ms, duration)

    time = fn ms ->
      el(
        [center_y(), Font.size(s(12)), Font.color(color_rgba(255, 255, 255, 0.9))],
        text(clock(ms))
      )
    end

    slider =
      Input.slider(
        [
          width(fill()),
          height(px(s(32))),
          center_y(),
          Input.Slider.config(
            min: 0,
            max: duration,
            step: 0,
            track:
              el(
                [
                  height(px(s(4))),
                  center_y(),
                  Border.rounded(s(2)),
                  Background.color(color_rgba(255, 255, 255, 0.3))
                ],
                none()
              ),
            filled_track:
              el(
                [height(px(s(4))), center_y(), Border.rounded(s(2)), Background.color(c(:white))],
                none()
              ),
            thumb:
              el(
                [
                  width(px(s(18))),
                  height(px(s(18))),
                  Border.rounded(s(9)),
                  Background.color(c(:white))
                ],
                none()
              )
          ),
          Event.on_change(event(videos, :seek))
        ],
        position
      )

    row([width(fill()), spacing(s(10))], [time.(position), slider, time.(duration)])
  end

  defp overlay_button(icon_name, on_press, size \\ 44) do
    Input.button(
      [
        width(px(s(size))),
        height(px(s(size))),
        center_y(),
        Border.rounded(s(size / 2)),
        Background.color(color_rgba(255, 255, 255, 0.14)),
        Event.on_press(on_press),
        Interactive.mouse_down([Background.color(color_rgba(255, 255, 255, 0.3))])
      ],
      el([center_x(), center_y()], icon(icon_name, round(size * 0.45), c(:white)))
    )
  end

  defp overlay_text(text_value) do
    el(
      [center_x(), center_y(), padding(s(16))],
      paragraph(
        [Font.center(), Font.size(s(14)), Font.color(color_rgba(255, 255, 255, 0.85))],
        [text(text_value)]
      )
    )
  end

  defp describe(:starting), do: "starting"
  defp describe(:playing), do: "playing"
  defp describe(:paused), do: "paused"
  defp describe(:ended), do: "finished"
  defp describe({:error, _}), do: "failed"

  defp describe_error(:no_hardware_decoder), do: "there's no hardware decoder here."
  defp describe_error(:no_h264_video), do: "it has no H.264 video."
  defp describe_error({:crashed, reason}), do: "the player stopped (#{inspect(reason)})."
  defp describe_error(reason), do: inspect(reason)

  defp clock(ms) do
    seconds = div(ms, 1000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
