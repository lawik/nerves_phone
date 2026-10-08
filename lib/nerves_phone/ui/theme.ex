defmodule NervesPhone.UI.Theme do
  @moduledoc """
  Colours, sizes and shared widgets for the UI.

  The look follows the "Windowed UI Concept" mockup: warm grey surfaces,
  a blue accent gradient, raised buttons and sunken wells. Sizes are in
  points for a 432 pt wide screen and scaled with `s/1`, so the same layout
  fills the FP3's 1080 px panel.
  """

  use Emerge.UI

  # The FP3's panel is 1080x2160 at ~430 dpi, so sizes are scaled up on
  # the phone. Set per target in config.
  @scale Application.compile_env(:nerves_phone, :ui_scale, 1)

  @font "IBM Plex Sans"
  @font_files [
    {300, "IBMPlexSans-Light.ttf"},
    {400, "IBMPlexSans-Regular.ttf"},
    {500, "IBMPlexSans-Medium.ttf"},
    {600, "IBMPlexSans-SemiBold.ttf"},
    {700, "IBMPlexSans-Bold.ttf"}
  ]

  @colors %{
    s0: {253, 252, 250},
    s1: {248, 246, 242},
    s2: {242, 239, 232},
    s3: {234, 230, 222},
    s4: {228, 224, 216},
    s5: {216, 212, 204},
    text: {26, 26, 26},
    dim: {112, 112, 106},
    faint: {160, 160, 152},
    acc_from: {26, 58, 122},
    acc_to: {74, 128, 200},
    red: {196, 48, 48},
    title_dim: {160, 192, 224},
    dock_from: {232, 240, 255},
    dock_to: {220, 228, 248},
    white: {255, 255, 255}
  }

  @doc "Scales a size in points to device pixels."
  def s(points), do: round(points * @scale)

  @doc "Font registrations for the viewport's renderer."
  def fonts do
    for {weight, file} <- @font_files,
        do: [family: @font, source: "fonts/" <> file, weight: weight]
  end

  def font, do: @font

  @doc "A palette colour by name, with optional alpha."
  def c(name, alpha \\ 1.0) do
    {r, g, b} = Map.fetch!(@colors, name)
    color_rgba(r, g, b, alpha)
  end

  @doc "A top-to-bottom gradient between two palette colours."
  def vgrad(from, to), do: gradient([c(from), c(to)], 90)

  @doc "The accent gradient used on title bars and badges."
  def accent, do: gradient([c(:acc_from), c(:acc_to)], 45)

  # ---------- Depth ----------

  def raised do
    [
      Border.shadow(offset: {0, s(1)}, blur: s(2), color: c(:text, 0.12)),
      Border.inner_shadow(offset: {0, s(1)}, blur: 0, color: c(:white, 0.5))
    ]
  end

  def pressed, do: [Border.inner_shadow(offset: {0, s(1)}, blur: s(3), color: c(:text, 0.15))]

  def sunken, do: [Border.inner_shadow(offset: {0, s(1)}, blur: s(3), color: c(:text, 0.10))]

  # ---------- Widgets ----------

  @doc "An SVG icon from priv/icons, tinted."
  def icon(name, size, tint) do
    svg([width(px(s(size))), height(px(s(size))), Svg.color(tint)], "icons/#{name}.svg")
  end

  @doc """
  An app's icon: its glyph in white on a rounded gradient square. `size`
  is the square's side in points.
  """
  def tile({from, to}, icon_name, size) do
    el(
      [
        width(px(s(size))),
        height(px(s(size))),
        Border.rounded(s(size * 0.22)),
        Background.color(gradient([rgb(from), rgb(to)], 45))
      ] ++ raised(),
      el([center_x(), center_y()], icon(icon_name, round(size * 0.55), c(:white)))
    )
  end

  defp rgb({r, g, b}), do: color_rgb(r, g, b)

  @doc "An on/off switch."
  def switch(on?, on_press) do
    Input.button(
      [
        width(px(s(52))),
        height(px(s(30))),
        padding(s(3)),
        Border.rounded(s(15)),
        Event.on_press(on_press),
        Background.color(if on?, do: accent(), else: vgrad(:s3, :s4))
      ] ++ sunken(),
      el(
        [
          width(px(s(24))),
          height(px(s(24))),
          if(on?, do: align_right(), else: align_left()),
          Border.rounded(s(12)),
          Background.color(vgrad(:s0, :s1))
        ] ++ raised(),
        none()
      )
    )
  end

  @doc "A raised button with text or elements; a nil `on_press` disables it. `opts`: `:primary`, `:selected`, `:fill`, `:color`, `:height`."
  def button(content, on_press, opts \\ []) do
    Input.button(
      [
        height(px(s(Keyword.get(opts, :height, 44)))),
        padding_xy(s(14), 0),
        Border.rounded(s(2)),
        Font.size(s(13)),
        Font.color(Keyword.get(opts, :color, c(:text))),
        if(opts[:primary], do: Font.semi_bold(), else: Font.regular()),
        if(opts[:fill], do: width(fill()), else: width(content()))
      ] ++
        if(on_press,
          do: [
            Event.on_press(on_press),
            Interactive.mouse_down([Background.color(vgrad(:s3, :s2))])
          ],
          else: []
        ) ++
        if(opts[:selected],
          do: [Background.color(vgrad(:s2, :s3)) | pressed()],
          else: [Background.color(vgrad(:s4, :s5)) | raised()]
        ),
      row(
        [center_x(), center_y(), spacing(s(6))],
        content |> List.wrap() |> Enum.map(&if(is_binary(&1), do: text(&1), else: &1))
      )
    )
  end

  @doc "A sunken progress bar showing `done` of `total`."
  def progress(done, total) do
    bar =
      el(
        [
          width(fill(Kernel.max(done, 0.001))),
          height(fill()),
          Border.rounded(s(5)),
          Background.color(
            if(done > 0, do: gradient([c(:acc_to), c(:acc_from)], 90), else: c(:s3, 0.0))
          )
        ],
        none()
      )

    rest = el([width(fill(Kernel.max(total - done, 0.001))), height(fill())], none())

    row(
      [width(fill()), height(px(s(10))), Border.rounded(s(5)), Background.color(vgrad(:s2, :s3))] ++
        sunken(),
      [bar, rest]
    )
  end

  @doc "An all-caps section label."
  def label(text_value) do
    el(
      [Font.size(s(10)), Font.medium(), Font.color(c(:faint)), Font.letter_spacing(s(0.5))],
      text(String.upcase(text_value))
    )
  end

  # ---------- Lists ----------

  @doc "A scrolling column of rows that fills the content area."
  def scroll_list(rows) do
    el(
      [width(fill()), height(fill()), scrollbar_y()],
      column([width(fill())], rows)
    )
  end

  @doc """
  A tappable list row: title, a dim line under it, and on the right a value
  (text) or an element. `selected?` marks the row with the accent and a
  check.
  """
  def list_row(key, on_press, title, meta, trailing, selected? \\ false) do
    Input.button(
      [
        key(key),
        width(fill()),
        padding_xy(s(12), s(10)),
        Border.width_each(0, 0, 1, 0),
        Border.color(c(:text, 0.05))
      ] ++
        if(on_press,
          do: [
            Event.on_press(on_press),
            Interactive.mouse_down([Background.color(c(:acc_from, 0.08))])
          ],
          else: []
        ) ++ if(selected?, do: [Background.color(c(:acc_from, 0.06))], else: []),
      row([width(fill()), spacing(s(10))], [
        column([width(fill()), center_y(), spacing(s(3))], [
          el(
            [
              Font.size(s(14)),
              Font.color(c(if selected?, do: :acc_from, else: :text)),
              if(selected?, do: Font.medium(), else: Font.regular())
            ],
            text(title)
          ),
          row([Font.size(s(11)), Font.light(), Font.color(c(:dim)), spacing(s(4))], [
            if(selected?, do: el([center_y()], icon(:check, 11, c(:acc_from))), else: none()),
            text(meta)
          ])
        ]),
        if(is_binary(trailing),
          do:
            el([center_y(), Font.size(s(12)), Font.light(), Font.color(c(:dim))], text(trailing)),
          else: el([center_y()], trailing)
        )
      ])
    )
  end

  @doc "A label and its value, side by side, for reading."
  def info_row(key, label_text, value) do
    row(
      [
        key(key),
        width(fill()),
        padding_xy(s(12), s(9)),
        spacing(s(12)),
        Border.width_each(0, 0, 1, 0),
        Border.color(c(:text, 0.05))
      ],
      [
        el([align_top(), Font.size(s(13)), Font.color(c(:dim))], text(label_text)),
        paragraph(
          [width(fill()), Font.size(s(13)), Font.align_right(), Font.color(c(:text))],
          [text(value)]
        )
      ]
    )
  end

  @doc "A section label over rows, keyed like the rows around it."
  def section(title) do
    el(
      [key({:section, title}), width(fill()), padding_each(s(14), s(12), s(4), s(12))],
      label(title)
    )
  end

  @doc "Four signal bars, `bars` of them lit."
  def signal_bars(bars, tint, dim \\ c(:text, 0.15)) do
    row(
      [spacing(s(1)), height(px(s(12)))],
      for i <- 1..4 do
        el(
          [
            width(px(s(3))),
            height(px(s(3 * i))),
            align_bottom(),
            Border.rounded(s(1)),
            Background.color(if i <= (bars || 0), do: tint, else: dim)
          ],
          none()
        )
      end
    )
  end

  @doc "Centered lines of text, the first one emphasised."
  def message(lines) do
    column(
      [width(fill()), padding(s(32)), spacing(s(10))],
      for {line, i} <- Enum.with_index(lines) do
        paragraph(
          [
            width(fill()),
            Font.center(),
            Font.size(s(if i == 0, do: 15, else: 13)),
            if(i == 0, do: Font.medium(), else: Font.light()),
            Font.color(c(if i == 0, do: :text, else: :dim))
          ],
          [text(line)]
        )
      end
    )
  end
end
