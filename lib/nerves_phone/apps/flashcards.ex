defmodule NervesPhone.Apps.Flashcards do
  @moduledoc """
  Flash cards for children, from Anki decks (`.apkg`, as shared on
  AnkiWeb), scheduled the way Anki does it: cards come back sooner when
  they're missed, and later and later as they're learnt.

  It's made to work without reading: icons, numbers and colours rather
  than words, past the decks' own names and what's on the cards.

    * **Decks** - a panel for each, with how many cards it has, how many
      are due (↻) and new (★) today, the last round's score, and the
      fastest perfect round once there is one. Tapping one marks it, greys
      the others out and runs a bar along it while the cards are dealt.
    * **Studying** - a bar for how far through, the card's prompt as big
      as it fits, and up to four answers to pick from
      (`NervesPhone.Flashcards.Quiz`). Right turns green and moves on by
      itself; wrong turns red, shows the right one in green, and waits for
      the arrow. Sounds play, and again with the speaker.
    * **Done** - a star, the score, a small star for each card (filled
      when it was right first time), and the time if the round was perfect
      and had the whole deck.

  Decks are in `NervesPhone.Flashcards.Library`, state in
  `NervesPhone.Apps.Flashcards.State`.
  """

  @behaviour NervesPhone.App

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [solve: 2, event: 3]

  @app NervesPhone.State

  @green {{72, 184, 120}, {24, 128, 112}}
  @red {{224, 96, 72}, {184, 48, 48}}
  @gold {{240, 160, 48}, {208, 96, 32}}

  @impl NervesPhone.App
  def name, do: "Flash Cards"

  @impl NervesPhone.App
  def icon, do: :cards

  @impl NervesPhone.App
  def tile, do: @green

  @impl NervesPhone.App
  def controllers, do: [[name: :flashcards, module: NervesPhone.Apps.Flashcards.State]]

  @impl NervesPhone.App
  def opened, do: Solve.dispatch(@app, :flashcards, :opened, nil)

  @impl NervesPhone.App
  def closed, do: Solve.dispatch(@app, :flashcards, :decks, nil)

  @impl NervesPhone.App
  def toolbar, do: []

  # The deck's name while it's studied; nothing to read otherwise.
  @impl NervesPhone.App
  def status do
    case solve(@app, :flashcards) do
      %{page: page, session: %{name: name}} when page in [:study, :done] -> name
      _ -> ""
    end
  end

  # Back leaves a deck, or stops one opening.
  @impl NervesPhone.App
  def back do
    cards = solve(@app, :flashcards)
    if cards.page != :decks or cards.opening, do: event(cards, :decks, nil)
  end

  @impl NervesPhone.App
  def render do
    cards = solve(@app, :flashcards)

    case {cards.page, cards.session} do
      {:study, %{card: %{}} = session} -> study(cards, session)
      {:done, %{} = session} -> done(cards, session)
      _ -> decks(cards)
    end
  end

  # ---------- Decks ----------

  defp decks(%{decks: [], loading: true}) do
    el([width(px(s(200))), center_x(), center_y()], loading_bar())
  end

  # For the grown-ups.
  defp decks(%{decks: []}) do
    message([
      "No flash cards yet.",
      "Copy Anki decks (.apkg files) to /data/flashcards on the phone."
    ])
  end

  defp decks(cards) do
    el(
      [width(fill()), height(fill()), scrollbar_y()],
      column(
        [width(fill()), padding(s(12)), spacing(s(10))],
        Enum.map(cards.decks, &deck(cards, &1))
      )
    )
  end

  # A panel for the deck. While a deck opens, it's marked and has a bar
  # running along it, and the others are greyed out and can't be picked.
  defp deck(cards, deck) do
    opening? = cards.opening == deck.id
    idle? = cards.opening == nil

    counts =
      if deck.due + deck.new == 0 do
        [el([center_y()], icon(:check, 16, c(:acc_from)))]
      else
        [
          if(deck.due > 0, do: badge(:refresh, deck.due, c(:acc_from)), else: none()),
          if(deck.new > 0, do: badge(:star, deck.new, rgb(elem(@green, 1))), else: none())
        ]
      end

    look =
      cond do
        opening? ->
          [
            Border.width(s(2)),
            Border.color(c(:acc_from)),
            Background.color(vgrad(:dock_from, :dock_to))
          ] ++ pressed()

        idle? ->
          [
            Border.width(1),
            Border.color(c(:text, 0.12)),
            Background.color(vgrad(:s0, :s1)),
            Event.on_press(event(cards, :study, deck.id)),
            Interactive.mouse_down(pressed())
          ] ++ raised()

        true ->
          [
            Border.width(1),
            Border.color(c(:text, 0.06)),
            Background.color(c(:s2)),
            Transform.alpha(0.45)
          ]
      end

    Input.button(
      [key({:deck, deck.id}), width(fill()), padding(s(12)), Border.rounded(s(3))] ++ look,
      column([width(fill()), spacing(s(10))], [
        row([width(fill()), spacing(s(12))], [
          el([center_y()], tile(tile(), :cards, 44)),
          column([width(fill()), center_y(), spacing(s(4))], [
            if(deck.parent,
              do: el([Font.size(s(11)), Font.light(), Font.color(c(:dim))], text(deck.parent)),
              else: none()
            ),
            paragraph(
              [width(fill()), Font.size(s(16)), Font.semi_bold(), Font.color(c(:text))],
              [text(deck.name)]
            ),
            wrapped_row(
              [width(fill()), spacing_xy(s(8), s(6))],
              [stat(:cards, "#{deck.total}", c(:dim))] ++ counts ++ results(deck)
            )
          ])
        ]),
        if(opening?, do: loading_bar(), else: none())
      ])
    )
  end

  # The last round's score (gold when it was perfect) and the fastest
  # perfect round: nothing until there's been one.
  defp results(deck) do
    score =
      case deck.last do
        {right, cards} ->
          tint = if right == cards, do: rgb(elem(@gold, 0)), else: c(:dim)
          stat(:star_filled, "#{right}/#{cards}", tint)

        nil ->
          none()
      end

    time = if deck.best_ms, do: stat(:timer, duration(deck.best_ms), c(:dim)), else: none()
    [score, time]
  end

  # An icon and a number, quietly.
  defp stat(icon_name, value, tint) do
    row([center_y(), spacing(s(3))], [
      el([center_y()], icon(icon_name, 13, tint)),
      el([center_y(), Font.size(s(12)), Font.light(), Font.color(tint)], text(value))
    ])
  end

  # An icon and a number on a coloured pill.
  defp badge(icon_name, count, color) do
    row(
      [
        center_y(),
        padding_xy(s(7), s(2)),
        spacing(s(3)),
        Border.rounded(s(8)),
        Background.color(color)
      ],
      [
        el([center_y()], icon(icon_name, 11, c(:white))),
        el([center_y(), Font.size(s(12)), Font.medium(), Font.color(c(:white))], text("#{count}"))
      ]
    )
  end

  # A bar with a piece running back and forth along it, for waits that
  # can't say how far they've come. The gaps either side of the piece
  # trade their width.
  defp loading_bar do
    gap = fn from, to ->
      Animation.animate(
        [[width(from)], [width(to)], [width(from)]],
        1_400,
        :ease_in_out,
        :loop
      )
    end

    row(
      [
        width(fill()),
        height(px(s(6))),
        Border.rounded(s(3)),
        Background.color(vgrad(:s2, :s3))
      ] ++ sunken(),
      [
        el([height(fill()), gap.(px(0), fill(70))], none()),
        el(
          [
            width(fill(30)),
            height(fill()),
            Border.rounded(s(3)),
            Background.color(gradient([c(:acc_to), c(:acc_from)], 0))
          ],
          none()
        ),
        el([height(fill()), gap.(fill(70), px(0))], none())
      ]
    )
  end

  # ---------- Studying ----------

  # How far through, the prompt on a sheet of paper, and the answers in
  # two rows under it. After a wrong pick, the arrow to go on.
  defp study(cards, session) do
    question = session.question
    shown = Enum.reject(question.prompt, &match?({:sound, _}, &1))

    prompt =
      if shown == [] do
        # Only a sound: a big button to hear it again.
        el([center_x(), center_y()], round_button(:volume_3, event(cards, :replay, nil), 112))
      else
        blocks(shown, session.media_dir, :prompt)
      end

    replay =
      if question.sounds != [] and shown != [],
        do:
          el(
            [align_right(), align_top(), padding(s(8))],
            round_button(:volume_3, event(cards, :replay, nil), 48)
          ),
        else: none()

    sheet =
      el(
        [
          width(fill()),
          height(fill(5)),
          padding(s(16)),
          Border.rounded(s(4)),
          Border.width(1),
          Border.color(c(:text, 0.12)),
          Background.color(c(:white)),
          Nearby.in_front(replay)
        ] ++ raised(),
        prompt
      )

    choices =
      question.choices
      |> Enum.with_index()
      |> Enum.map(fn {blocks, index} -> choice(cards, session, blocks, index) end)
      |> Enum.chunk_every(2)
      |> Enum.map(&row([width(fill()), height(fill()), spacing(s(10))], &1))

    wrong? = session.picked != nil and session.picked != question.correct

    column([width(fill()), height(fill()), padding(s(12)), spacing(s(12))], [
      progress(session.studied, session.studied + session.left),
      sheet,
      column([width(fill()), height(fill(4)), spacing(s(10))], choices),
      if(wrong?, do: next_button(cards), else: none())
    ])
  end

  # An answer to pick. Once one's picked: the right answer is green with a
  # tick, a wrong pick red with a cross, and the rest fade.
  defp choice(cards, session, blocks, index) do
    picked = session.picked
    right? = index == session.question.correct

    {look, mark} =
      cond do
        picked == nil ->
          {[
             Background.color(vgrad(:s0, :s1)),
             Border.color(c(:text, 0.15)),
             Event.on_press(event(cards, :pick, index)),
             Interactive.mouse_down(pressed())
           ] ++ raised(), nil}

        right? ->
          {[Background.color(grad(@green)), Border.color(rgb(elem(@green, 1)))] ++ raised(),
           :check}

        index == picked ->
          {[Background.color(grad(@red)), Border.color(rgb(elem(@red, 1)))] ++ pressed(), :cross}

        true ->
          {[Background.color(c(:s2)), Border.color(c(:text, 0.06)), Transform.alpha(0.4)], nil}
      end

    tint = if mark, do: :white, else: :text

    badge =
      if mark,
        do: el([align_right(), align_top(), padding(s(6))], icon(mark, 22, c(:white))),
        else: none()

    Input.button(
      [
        width(fill()),
        height(fill()),
        padding(s(8)),
        Border.rounded(s(3)),
        Border.width(s(2)),
        Nearby.in_front(badge)
      ] ++ look,
      blocks(blocks, session.media_dir, {:choice, tint})
    )
  end

  defp next_button(cards) do
    Input.button(
      [
        width(fill()),
        height(px(s(64))),
        Border.rounded(s(3)),
        Background.color(accent()),
        Event.on_press(event(cards, :next, nil)),
        Interactive.mouse_down(pressed())
      ] ++ raised(),
      el([center_x(), center_y()], icon(:next, 32, c(:white)))
    )
  end

  defp round_button(icon_name, on_press, size) do
    Input.button(
      [
        width(px(s(size))),
        height(px(s(size))),
        Border.rounded(s(size / 2)),
        Background.color(vgrad(:s2, :s3)),
        Event.on_press(on_press),
        Interactive.mouse_down(pressed())
      ] ++ raised(),
      el([center_x(), center_y()], icon(icon_name, round(size * 0.45), c(:acc_from)))
    )
  end

  # Pictures share the height between them; text sits together in the
  # middle.
  defp blocks(blocks, dir, place) do
    content = Enum.map(blocks, &block(&1, dir, place))

    if Enum.any?(blocks, &match?({:image, _}, &1)),
      do: column([width(fill()), height(fill()), spacing(s(8))], content),
      else: column([width(fill()), center_y(), spacing(s(12))], content)
  end

  # Text as big as its length allows: a letter or a sum fills the space,
  # a sentence reads comfortably.
  defp block({:text, line}, _dir, place) do
    sizes = if place == :prompt, do: [96, 44, 28, 18], else: [48, 32, 20, 14]
    tint = if place == :prompt, do: :text, else: elem(place, 1)

    size =
      case String.length(line) do
        n when n <= 3 -> Enum.at(sizes, 0)
        n when n <= 12 -> Enum.at(sizes, 1)
        n when n <= 40 -> Enum.at(sizes, 2)
        _ -> Enum.at(sizes, 3)
      end

    paragraph(
      [width(fill()), Font.center(), Font.size(s(size)), Font.medium(), Font.color(c(tint))],
      [text(line)]
    )
  end

  defp block({:image, name}, dir, _place) do
    image([width(fill()), height(fill()), image_fit(:contain)], {:path, Path.join(dir, name)})
  end

  defp block(:divider, _dir, _place) do
    el(
      [width(fill()), height(px(s(2))), Border.rounded(s(1)), Background.color(c(:text, 0.1))],
      none()
    )
  end

  # ---------- Done ----------

  # A big star, the score, a small star for each card (filled when it was
  # right first time), the time of a perfect round of the whole deck (with
  # a star if it's the fastest yet), and the way back to the decks.
  defp done(cards, session) do
    gold = rgb(elem(@gold, 0))

    stars =
      for right? <- session.marks do
        if right?,
          do: el([], icon(:star_filled, 24, gold)),
          else: el([], icon(:star, 24, c(:faint)))
      end

    summary =
      case session.result do
        %{right: right, cards: total} = result ->
          row([center_x(), spacing(s(20))], [
            big_stat(:star_filled, "#{right}/#{total}", gold),
            if(result.ms,
              do: big_stat(:timer, duration(result.ms), if(result.best, do: gold, else: c(:dim))),
              else: none()
            )
          ])

        nil ->
          none()
      end

    column([width(fill()), height(fill()), padding(s(24)), spacing(s(20))], [
      el([center_x(), padding_each(s(24), 0, 0, 0)], tile(@gold, :star, 112)),
      summary,
      el(
        [width(fill()), height(fill()), scrollbar_y()],
        wrapped_row([width(fill()), spacing_xy(s(6), s(6))], stars)
      ),
      Input.button(
        [
          width(fill()),
          height(px(s(64))),
          Border.rounded(s(3)),
          Background.color(accent()),
          Event.on_press(event(cards, :decks, nil)),
          Interactive.mouse_down(pressed())
        ] ++ raised(),
        el([center_x(), center_y()], icon(:cards, 32, c(:white)))
      )
    ])
  end

  defp big_stat(icon_name, value, tint) do
    row([center_y(), spacing(s(6))], [
      el([center_y()], icon(icon_name, 28, tint)),
      el([center_y(), Font.size(s(28)), Font.medium(), Font.color(tint)], text(value))
    ])
  end

  # Minutes and seconds, as 1:05.
  defp duration(ms) do
    seconds = div(ms + 500, 1000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp rgb({r, g, b}), do: color_rgb(r, g, b)
  defp grad({from, to}), do: gradient([rgb(from), rgb(to)], 45)
end
