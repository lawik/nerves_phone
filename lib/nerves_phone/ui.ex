defmodule NervesPhone.UI do
  @moduledoc """
  The phone's screen, an Emerge viewport: a home screen of apps, and the
  frame an app runs in.

      ┌ title bar: app name ── downloads · network · battery ┐
      │ toolbar (the app's, if it has one)            │
      │ content: the home screen, or the app          │
      └ [Back]  status                         [Home] ┘

  Home shows a tile for each app in `NervesPhone.App.all/0`. Back goes to
  where the app says (`c:NervesPhone.App.back/0`), or home.

  It renders full screen on the FP3 panel through DRM, and opens a window
  when run on the host with `iex -S mix`. State lives in
  `NervesPhone.State`; this module only renders it and turns touches into
  events for its controllers.

  Updates from the controllers of an app that isn't on screen don't
  re-render, and nothing re-renders while the screen is off.
  """

  use Emerge
  use Solve.Lookup

  import NervesPhone.UI.Theme

  alias NervesPhone.App

  @app NervesPhone.State

  @impl Viewport
  def mount(opts) do
    defaults =
      [
        title: "Nerves Phone",
        width: 432,
        height: 864,
        otp_app: :nerves_phone,
        assets: [
          fonts: fonts(),
          # Video thumbnails, next to the videos, and the pictures on
          # flash cards.
          runtime_paths: [
            enabled: true,
            allowlist:
              NervesPhone.Video.Library.roots() ++ [NervesPhone.Flashcards.Library.cache_dir()]
          ]
        ]
      ]
      |> Keyword.merge(Application.get_env(:nerves_phone, :viewport, []))

    {:ok, %{}, Keyword.merge(defaults, opts)}
  end

  @impl Viewport
  def render(_state) do
    shell = solve(@app, :shell)
    device = solve(@app, :device)
    downloads = solve(@app, :downloads)
    app = shell.active

    screen =
      if app && App.fullscreen?(app) do
        fullscreen(app, device)
      else
        framed(app, shell, device, downloads)
      end

    oriented(device.orientation.orientation, screen)
  end

  # The screen is laid out for a 432x864 pt portrait panel. Held sideways,
  # it's laid out 864x432 and turned a quarter, with a layout-aware
  # rotation, so touches land where things are drawn. Apps that lay out
  # with fill() fit either way.
  @portrait {432, 864}

  defp oriented(:portrait, screen), do: screen

  defp oriented(side, screen) do
    {short, long} = @portrait

    el(
      [width(fill()), height(fill())],
      el(
        [
          width(px(s(long))),
          height(px(s(short))),
          rotate(if side == :landscape_left, do: 90, else: -90)
        ],
        screen
      )
    )
  end

  # The app on its own, edge to edge.
  defp fullscreen(app, device) do
    el(
      [width(fill()), height(fill()), Font.family(font()), Background.color(color_rgb(0, 0, 0))] ++
        overlays(device),
      app.render()
    )
  end

  # Over everything: the volume for a moment after it changes, and while
  # the screen is off, the touch catcher.
  defp overlays(device) do
    if(device.volume_overlay, do: [Nearby.in_front(volume_overlay(device))], else: []) ++
      if(device.screen_on, do: [], else: [Nearby.in_front(touch_catcher(device))])
  end

  # The volume, as a small window near the top of the screen: an accent
  # title strip, and a sunken well of one block a step, lit up to the
  # volume.
  defp volume_overlay(device) do
    %{volume: volume, volume_steps: steps} = device

    blocks =
      for i <- 1..steps do
        el(
          [
            width(fill()),
            height(fill()),
            Border.rounded(s(1)),
            Background.color(
              if i <= volume,
                do: gradient([c(:acc_to), c(:acc_from)], 90),
                else: c(:text, 0.06)
            )
          ],
          none()
        )
      end

    window =
      column(
        [
          width(px(s(260))),
          Border.rounded(s(3)),
          Border.width(1),
          Border.color(c(:text, 0.18)),
          Background.color(vgrad(:s1, :s3)),
          Border.shadow(offset: {0, s(3)}, blur: s(10), color: c(:text, 0.3))
        ],
        [
          row(
            [
              width(fill()),
              height(px(s(28))),
              padding_xy(s(8), 0),
              spacing(s(6)),
              Border.rounded_each(s(2), s(2), 0, 0),
              Background.color(accent())
            ],
            [
              el([center_y()], icon(volume_icon(volume, steps), 15, c(:white))),
              el(
                [
                  center_y(),
                  width(fill()),
                  Font.size(s(12)),
                  Font.semi_bold(),
                  Font.color(c(:white))
                ],
                text("Volume")
              ),
              el(
                [center_y(), Font.size(s(12)), Font.color(c(:white, 0.85))],
                text("#{volume}/#{steps}")
              )
            ]
          ),
          el(
            [width(fill()), padding(s(10))],
            row(
              [
                width(fill()),
                height(px(s(18))),
                padding(s(3)),
                spacing(s(2)),
                Border.rounded(s(2)),
                Background.color(vgrad(:s2, :s3))
              ] ++ sunken(),
              blocks
            )
          )
        ]
      )

    el([center_x(), align_top(), padding_xy(0, s(64))], window)
  end

  defp framed(app, shell, device, downloads) do
    {title, toolbar, content, status, back} =
      if app do
        {app.name(), app.toolbar(), app.render(), app.status(), app.back() || home(shell)}
      else
        {"Home", [], home_screen(shell), device.hostname, nil}
      end

    home = if app, do: home(shell)
    content = el([width(fill()), height(fill()), Background.color(vgrad(:s0, :s1))], content)

    body =
      if device.orientation.orientation == :portrait do
        [
          titlebar(app, title, nil, device, downloads),
          if(toolbar == [], do: none(), else: toolbar(toolbar)),
          content,
          nav_bar(back, status, home)
        ]
      else
        # Sideways, height is short, so the toolbar and Back and Home move
        # to the sides, and the status goes in the title bar.
        [
          titlebar(app, title, status, device, downloads),
          row([width(fill()), height(fill())], [
            if(toolbar == [], do: none(), else: toolbar_rail(toolbar)),
            content,
            nav_rail(back, home)
          ])
        ]
      end

    column(
      [
        width(fill()),
        height(fill()),
        Font.family(font()),
        Font.color(c(:text)),
        Background.color(c(:s4))
      ] ++ overlays(device),
      body
    )
  end

  defp home(shell), do: event(shell, :home, nil)

  # While the screen is off, a full-screen catcher takes the touch that
  # wakes it, so that touch doesn't also press what's underneath.
  defp touch_catcher(device) do
    Input.button(
      [width(fill()), height(fill()), Event.on_press(event(device, :wake, nil))],
      none()
    )
  end

  # ---------- Home ----------

  # Four tiles a row, of the apps the schedule allows now.
  defp home_screen(shell) do
    tiles =
      for app <- App.all(), app in shell.available do
        Input.button(
          [
            key(app),
            width(px(s(96))),
            padding_xy(0, s(8)),
            Border.rounded(s(4)),
            Event.on_press(event(shell, :open, app)),
            Interactive.mouse_down([Background.color(c(:acc_from, 0.08))])
          ],
          column([center_x(), spacing(s(6))], [
            el([center_x()], tile(app.tile(), app.icon(), 60)),
            el([center_x(), Font.size(s(12)), Font.color(c(:text))], text(app.name()))
          ])
        )
      end

    el(
      [width(fill()), height(fill()), padding_xy(s(12), s(20))],
      wrapped_row([width(fill()), spacing_xy(s(8), s(16))], tiles)
    )
  end

  # ---------- Title bar ----------

  # The status is only in the title bar when the phone's held sideways.
  defp titlebar(app, title, status, device, downloads) do
    badge =
      if app do
        el([center_y()], tile(app.tile(), app.icon(), 22))
      else
        el(
          [
            width(px(s(22))),
            height(px(s(22))),
            center_y(),
            Border.rounded(s(3)),
            Background.color(c(:white, 0.18))
          ],
          el([center_x(), center_y()], icon(:apps, 13, c(:white)))
        )
      end

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
        badge,
        row([center_y(), width(fill()), spacing(s(14))], [
          el(
            [center_y(), Font.size(s(16)), Font.semi_bold(), Font.color(c(:white))],
            text(title)
          ),
          if(status,
            do: el([center_y(), Font.size(s(12)), Font.color(c(:white, 0.75))], text(status)),
            else: none()
          )
        ]),
        downloads_indicator(downloads),
        volume_indicator(device),
        network_indicator(device.network),
        battery_indicator(device.battery)
      ]
    )
  end

  # The number of downloads, and the oldest's percentage when it reports
  # one: "2 · 45%".
  defp downloads_indicator(%{count: 0}), do: none()

  defp downloads_indicator(%{count: count, percent: percent}) do
    label = if percent, do: "#{count} · #{percent}%", else: "#{count}"

    row([center_y(), spacing(s(4))], [
      el([center_y()], icon(:download, 16, c(:white))),
      el([center_y(), Font.size(s(11)), Font.color(c(:white))], text(label))
    ])
  end

  # Set with the volume buttons.
  defp volume_indicator(%{volume: volume, volume_steps: steps}),
    do: el([center_y()], icon(volume_icon(volume, steps), 18, c(:white)))

  defp volume_icon(volume, steps) do
    cond do
      volume == 0 -> :volume_0
      volume <= div(steps, 3) -> :volume_1
      volume <= div(2 * steps, 3) -> :volume_2
      true -> :volume_3
    end
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
      if(network.bars,
        do: el([center_y()], signal_bars(network.bars, tint, c(:white, 0.3))),
        else: none()
      ),
      el([center_y(), Font.size(s(11)), Font.color(tint)], text(label))
    ])
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

  # ---------- Toolbar ----------

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
      Enum.map(items, &tool(&1, :bar))
    )
  end

  # The toolbar down the left side, when the phone's held sideways.
  defp toolbar_rail(items) do
    column(
      [
        width(px(s(84))),
        height(fill()),
        padding(s(4)),
        spacing(s(3)),
        scrollbar_y(),
        Background.color(vgrad(:s4, :s5)),
        Border.width_each(0, 1, 0, 0),
        Border.color(c(:text, 0.06))
      ],
      Enum.map(items, &tool(&1, :rail))
    )
  end

  defp tool(:separator, :bar) do
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

  defp tool(:separator, :rail) do
    el(
      [
        width(fill()),
        height(px(1)),
        Background.color(c(:text, 0.08)),
        Border.shadow(offset: {0, 1}, blur: 0, color: c(:white, 0.3))
      ],
      none()
    )
  end

  defp tool({icon_name, label, on_press, active?}, place) do
    tint = if active?, do: c(:text), else: c(:dim)

    size =
      case place do
        # Up to 76 wide, narrower when a page has more tools than fit.
        :bar -> [width(Emerge.UI.Size.min(px(s(76)), fill())), height(px(s(54)))]
        :rail -> [width(fill()), height(px(s(44)))]
      end

    Input.button(
      size ++
        [
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
            Font.color(tint)
          ],
          text(String.upcase(label))
        )
      ])
    )
  end

  # ---------- Bottom bar ----------

  # Back and Home around the status. On the home screen there's nowhere to
  # go, so both are dimmed.
  defp nav_bar(back, status, home) do
    row(
      [
        width(fill()),
        padding(s(4)),
        spacing(s(4)),
        Background.color(vgrad(:s4, :s5)),
        Border.width_each(1, 0, 0, 0),
        Border.color(c(:text, 0.06))
      ],
      [
        nav_button(:back, back),
        el(
          [
            width(fill()),
            height(px(s(44))),
            padding_xy(s(10), 0),
            Border.rounded(s(2)),
            Background.color(vgrad(:s2, :s3)),
            Font.size(s(11)),
            Font.light(),
            Font.color(c(:dim))
          ] ++ sunken(),
          el([center_y()], text(status))
        ),
        nav_button(:home, home)
      ]
    )
  end

  # Back at the top and Home at the bottom of the right side, when the
  # phone's held sideways.
  defp nav_rail(back, home) do
    column(
      [
        height(fill()),
        padding(s(4)),
        Background.color(vgrad(:s4, :s5)),
        Border.width_each(0, 0, 0, 1),
        Border.color(c(:text, 0.06))
      ],
      [nav_button(:back, back), el([height(fill())], none()), nav_button(:home, home)]
    )
  end

  defp nav_button(icon_name, nil) do
    el(
      [width(px(s(56))), height(px(s(44))), Border.rounded(s(2))],
      el([center_x(), center_y()], icon(icon_name, 20, c(:faint)))
    )
  end

  defp nav_button(icon_name, on_press) do
    Input.button(
      [
        width(px(s(56))),
        height(px(s(44))),
        Border.rounded(s(2)),
        Background.color(vgrad(:s0, :s1)),
        Event.on_press(on_press),
        Interactive.mouse_down([Background.color(vgrad(:s3, :s2)) | pressed()])
      ] ++ raised(),
      el([center_x(), center_y()], icon(icon_name, 20, c(:text)))
    )
  end

  # Skip the re-render while the screen is off (waking re-renders), and when
  # only apps that aren't on screen changed.
  @impl Solve.Lookup
  def handle_solve_updated(updated, state) do
    refs = updated |> Map.values() |> Enum.flat_map(& &1.refs)
    screen_off? = not solve(@app, :device).screen_on
    active = solve(@app, :shell).active
    hidden = for app <- App.all(), app != active, name <- App.controller_names(app), do: name

    cond do
      screen_off? and :device not in refs -> {:ok, state}
      refs != [] and Enum.all?(refs, &(&1 in hidden)) -> {:ok, state}
      true -> {:ok, Viewport.rerender(state)}
    end
  end
end
