defmodule NervesPhone.UI do
  @moduledoc """
  The phone's main screen, an Emerge viewport: a music player laid out like
  the mobile half of the "Windowed UI Concept".

  Every playlist or album you open becomes a chip in the dock under the
  toolbar, next to the playlists, search and what's playing:

      ┌ titlebar ─────── volume · network · battery ┐
      │ toolbar (changes with the view)             │
      │ dock: [Playlists] [Search] [Playing] [Mix ×]│
      │ content: playlists, tracks, search, playing │
      │ mini player (except on Playing)             │
      └ status bar ─────────────────────────────────┘

  It renders full screen on the FP3 panel through DRM, and opens a window
  when run on the host with `iex -S mix`. State lives in
  `NervesPhone.State`; this module only renders it and turns touches into
  events for its controllers.

  Playback progress changes every poll. When that's all that changed and
  the Playing view isn't on screen, nothing is re-rendered, so long lists
  aren't rebuilt every two seconds.
  """

  use Emerge
  use Solve.Lookup

  import NervesPhone.UI.Theme

  alias NervesPhone.Music.Covers
  alias NervesPhone.UI.{LibraryView, NowPlayingView, SearchView, TracksView}

  @app NervesPhone.State

  @impl Viewport
  def mount(opts) do
    File.mkdir_p!(Covers.dir())

    defaults =
      [
        title: "Music",
        width: 432,
        height: 864,
        otp_app: :nerves_phone,
        assets: [
          fonts: fonts(),
          # Covers are decoded at the size they're drawn, not their full
          # 640 px.
          decode_at_size: true,
          # Cover art is downloaded at runtime. On the phone /data is a
          # symlink to /root.
          runtime_paths: [enabled: true, allowlist: [Covers.dir()], follow_symlinks: true]
        ]
      ]
      |> Keyword.merge(Application.get_env(:nerves_phone, :viewport, []))

    {:ok, %{player_seen: nil}, Keyword.merge(defaults, opts)}
  end

  @impl Viewport
  def render(_state) do
    library = solve(@app, :library)
    workspace = solve(@app, :workspace)
    player = solve(@app, :player)
    device = solve(@app, :device)

    {toolbar, content, status} =
      case workspace.active do
        :library ->
          {LibraryView.toolbar(library, workspace),
           LibraryView.render(library, workspace, player), LibraryView.status(library)}

        :search ->
          {SearchView.toolbar(workspace), SearchView.render(workspace, player),
           SearchView.status(workspace)}

        :now_playing ->
          {NowPlayingView.toolbar(workspace), NowPlayingView.render(player),
           NowPlayingView.status(player)}

        _context ->
          context = workspace.context

          {TracksView.toolbar(context, workspace, player),
           TracksView.render(context, workspace, player), TracksView.status(context)}
      end

    column(
      [
        width(fill()),
        height(fill()),
        Font.family(font()),
        Font.color(c(:text)),
        Background.color(c(:s4))
      ] ++ if(device.screen_on, do: [], else: [Nearby.in_front(touch_catcher(device))]),
      [
        titlebar(device, player),
        toolbar(toolbar),
        dock(workspace, player),
        el([width(fill()), height(fill()), Background.color(vgrad(:s0, :s1))], content),
        if(workspace.active != :now_playing and player.track,
          do: mini_player(workspace, player),
          else: none()
        ),
        status_bar({status, play_state(player)})
      ]
    )
  end

  # While the screen is off, a full-screen catcher takes the touch that
  # wakes it, so that touch doesn't also press what's underneath.
  defp touch_catcher(device) do
    Input.button(
      [width(fill()), height(fill()), Event.on_press(event(device, :wake, nil))],
      none()
    )
  end

  defp play_state(player) do
    cond do
      player.pending -> "Starting…"
      player.track && player.is_playing -> "Playing"
      player.track -> "Paused"
      player.device_ready -> "Ready"
      true -> "Connecting…"
    end
  end

  defp titlebar(device, player) do
    row(
      [
        width(fill()),
        height(px(s(48))),
        padding_xy(s(12), 0),
        spacing(s(8)),
        Background.color(accent()),
        Border.shadow(offset: {0, s(1)}, blur: s(3), color: c(:text, 0.12))
      ],
      [
        el(
          [
            width(px(s(22))),
            height(px(s(22))),
            center_y(),
            Border.rounded(s(3)),
            Background.color(gradient([c(:list_ico_from), c(:list_ico_to)], 45))
          ],
          el([center_x(), center_y()], icon(:music, 13, c(:white)))
        ),
        el(
          [center_y(), width(fill()), Font.size(s(16)), Font.semi_bold(), Font.color(c(:white))],
          text("Music")
        ),
        volume_indicator(player),
        network_indicator(device.network),
        battery_indicator(device.battery)
      ]
    )
  end

  # Set with the volume buttons.
  defp volume_indicator(%{volume: volume, volume_steps: steps}) do
    icon_name =
      cond do
        volume == 0 -> :volume_0
        volume <= div(steps, 3) -> :volume_1
        volume <= div(2 * steps, 3) -> :volume_2
        true -> :volume_3
      end

    el([center_y()], icon(icon_name, 18, c(:white)))
  end

  defp network_indicator(network) do
    {icon_name, label} =
      case network.kind do
        :wifi -> {:wifi, "Wi-Fi"}
        :cellular -> {:cell, "Mobile"}
        :ethernet -> {:ethernet, "Ethernet"}
        :usb -> {:usb, "USB"}
        :offline -> {:offline, "Offline"}
      end

    # Connected without internet (USB to a laptop, say) is dimmed.
    tint = if network.internet, do: c(:white), else: c(:title_dim)

    # Mobile's icon is already bars; with a signal reading, the bars say it.
    show_icon? = not (network.kind == :cellular and network.bars != nil)

    row([center_y(), spacing(s(4))], [
      if(show_icon?, do: el([center_y()], icon(icon_name, 16, tint)), else: none()),
      if(network.bars, do: el([center_y()], signal_bars(network.bars, tint)), else: none()),
      el([center_y(), Font.size(s(11)), Font.color(tint)], text(label))
    ])
  end

  defp signal_bars(bars, tint) do
    row(
      [spacing(s(1)), height(px(s(12)))],
      for i <- 1..4 do
        el(
          [
            width(px(s(3))),
            height(px(s(3 * i))),
            align_bottom(),
            Border.rounded(s(1)),
            Background.color(if i <= bars, do: tint, else: c(:white, 0.3))
          ],
          none()
        )
      end
    )
  end

  defp battery_indicator(nil), do: none()

  defp battery_indicator(%{level: level, charging: charging}) do
    fill_color =
      cond do
        charging -> c(:white)
        level <= 15 -> color(:red, 400)
        true -> c(:white)
      end

    row([center_y(), spacing(s(4))], [
      if(charging, do: el([center_y()], icon(:bolt, 12, c(:white))), else: none()),
      row([center_y(), spacing(s(1))], [
        # The body, filled to the charge level, and the terminal nub.
        el(
          [
            width(px(s(24))),
            height(px(s(12))),
            padding(s(1.5)),
            Border.rounded(s(2.5)),
            Border.width(s(1)),
            Border.color(c(:white, 0.9))
          ],
          row([width(fill()), height(fill())], [
            el(
              [
                width(fill(Kernel.max(level, 1))),
                height(fill()),
                Border.rounded(s(1)),
                Background.color(fill_color)
              ],
              none()
            ),
            el([width(fill(Kernel.max(100 - level, 1)))], none())
          ])
        ),
        el(
          [
            width(px(s(2))),
            height(px(s(5))),
            center_y(),
            Border.rounded_each(0, s(1), s(1), 0),
            Background.color(c(:white, 0.9))
          ],
          none()
        )
      ]),
      el([center_y(), Font.size(s(11)), Font.color(c(:white))], text("#{level}%"))
    ])
  end

  defp toolbar(items) do
    row(
      [
        width(fill()),
        padding(s(4)),
        spacing(s(3)),
        Background.color(vgrad(:s4, :s5)),
        Border.width_each(0, 0, 1, 0),
        Border.color(c(:text, 0.06))
      ],
      Enum.map(items, &tool/1)
    )
  end

  defp tool(:separator) do
    el(
      [
        width(px(1)),
        height(px(s(40))),
        center_y(),
        Background.color(c(:text, 0.08)),
        Border.shadow(offset: {1, 0}, blur: 0, color: c(:white, 0.3))
      ],
      none()
    )
  end

  defp tool({icon_name, label, on_press, active?}) do
    tint = if active?, do: c(:text), else: c(:dim)

    Input.button(
      [
        width(px(s(76))),
        height(px(s(54))),
        Border.rounded(s(2)),
        Event.on_press(on_press),
        Interactive.mouse_down(pressed())
      ] ++ if(active?, do: [Background.color(vgrad(:s2, :s3)) | pressed()], else: []),
      column([center_x(), center_y(), spacing(s(3))], [
        el([center_x()], icon(icon_name, 20, tint)),
        el(
          [
            center_x(),
            Font.size(s(10)),
            Font.medium(),
            Font.color(tint),
            Font.letter_spacing(0.5)
          ],
          text(String.upcase(label))
        )
      ])
    )
  end

  # The open items dock: the playlists first, then search and what's
  # playing once used, then each opened playlist or album. It scrolls
  # sideways when there are more chips than fit.
  defp dock(workspace, player) do
    active = workspace.active

    fixed =
      [chip(:list, "Playlists", active == :library, event(workspace, :show, :library))] ++
        if(workspace.search_open,
          do: [
            chip(
              :search,
              "Search",
              active == :search,
              event(workspace, :show, :search),
              event(workspace, :close, :search)
            )
          ],
          else: []
        ) ++
        if(player.track,
          do: [
            chip(
              :playing,
              "Playing",
              active == :now_playing,
              event(workspace, :show, :now_playing)
            )
          ],
          else: []
        )

    contexts =
      for context <- workspace.open do
        chip(
          {context.kind, context.uri == player.context_uri},
          context.name,
          active == context.key,
          event(workspace, :show, context.key),
          event(workspace, :close, context.key)
        )
      end

    el(
      [width(fill()), scrollbar_x(), Background.color(vgrad(:s5, :s4))] ++ sunken(),
      row([padding_xy(s(8), s(6)), spacing(s(5))], fixed ++ contexts)
    )
  end

  defp chip(kind, label, active?, on_press, on_close \\ nil) do
    tint = if active?, do: c(:acc_from), else: c(:text)

    marker =
      case kind do
        :list -> swatch(:list, 12)
        :search -> icon(:search, 14, tint)
        :playing -> icon(:music, 14, tint)
        {_kind, true} -> icon(:playing, 14, c(:acc_from))
        {:album, false} -> icon(:album, 14, tint)
        {:playlist, false} -> swatch(:playlist, 12)
      end

    close =
      if on_close do
        [
          Input.button(
            [
              width(px(s(28))),
              height(px(s(28))),
              center_y(),
              Border.rounded(s(2)),
              Event.on_press(on_close),
              Interactive.mouse_down([Background.color(c(:text, 0.08))])
            ],
            el([center_x(), center_y()], icon(:close, 12, if(active?, do: tint, else: c(:faint))))
          )
        ]
      else
        []
      end

    row(
      [
        height(px(s(44))),
        padding_each(0, if(on_close, do: s(4), else: s(14)), 0, s(12)),
        spacing(s(6)),
        Border.rounded(s(2)),
        Background.color(if active?, do: vgrad(:dock_from, :dock_to), else: vgrad(:s0, :s1))
      ] ++
        if(active?,
          do: pressed() ++ [Border.glow(c(:acc_from, 0.25), s(1))],
          else: raised()
        ),
      [
        Input.button(
          [height(fill()), Event.on_press(on_press)],
          row([center_y(), spacing(s(6))], [
            el([center_y()], marker),
            el(
              [
                center_y(),
                Font.size(s(13)),
                Font.color(tint),
                if(active?, do: Font.medium(), else: Font.regular())
              ],
              text(label)
            )
          ])
        )
        | close
      ]
    )
  end

  # What's playing, with play/pause and next. Tapping it opens Playing.
  defp mini_player(workspace, player) do
    row(
      [
        width(fill()),
        padding_xy(s(10), s(6)),
        spacing(s(8)),
        Background.color(vgrad(:dock_from, :dock_to)),
        Border.width_each(1, 0, 0, 0),
        Border.color(c(:acc_from, 0.15))
      ],
      [
        Input.button(
          [width(fill()), Event.on_press(event(workspace, :show, :now_playing))],
          column([width(fill()), spacing(s(2))], [
            el(
              [Font.size(s(13)), Font.medium(), Font.color(c(:acc_from))],
              text(player.track.name)
            ),
            el([Font.size(s(11)), Font.light(), Font.color(c(:dim))], text(player.track.artists))
          ])
        ),
        mini_button(
          if(player.is_playing, do: :pause, else: :play),
          event(player, :toggle_play, nil)
        ),
        mini_button(:next, event(player, :next, nil))
      ]
    )
  end

  defp mini_button(icon_name, on_press) do
    Input.button(
      [
        width(px(s(44))),
        height(px(s(44))),
        center_y(),
        Border.rounded(s(22)),
        Event.on_press(on_press),
        Interactive.mouse_down([Background.color(c(:acc_from, 0.12))])
      ],
      el([center_x(), center_y()], icon(icon_name, 20, c(:acc_from)))
    )
  end

  defp status_bar({main, side}) do
    row(
      [width(fill()), padding(s(3)), spacing(s(2)), Background.color(vgrad(:s4, :s5))],
      [status_cell(main, fill(3)), status_cell(side, fill(1))]
    )
  end

  defp status_cell(value, size) do
    el(
      [
        width(size),
        padding_xy(s(8), s(6)),
        Border.rounded(s(2)),
        Background.color(vgrad(:s2, :s3)),
        Font.size(s(11)),
        Font.light(),
        Font.color(c(:dim))
      ] ++ sunken(),
      text(value)
    )
  end

  # Skip the re-render when only playback progress moved and it isn't
  # shown, and while the screen is off (waking re-renders).
  @impl Solve.Lookup
  def handle_solve_updated(updated, state) do
    player = solve(@app, :player)
    seen = Map.delete(player, :progress_ms)
    refs = updated |> Map.values() |> Enum.flat_map(& &1.refs)
    screen_off? = not solve(@app, :device).screen_on

    cond do
      screen_off? and :device not in refs ->
        {:ok, state}

      refs == [:player] and seen == state.player_seen and
          solve(@app, :workspace).active != :now_playing ->
        {:ok, state}

      true ->
        {:ok, Viewport.rerender(%{state | player_seen: seen})}
    end
  end
end
