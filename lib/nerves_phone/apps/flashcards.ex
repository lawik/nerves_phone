defmodule NervesPhone.Apps.Flashcards do
  @moduledoc """
  Flash cards, from Anki decks (`.apkg`, as shared on AnkiWeb), studied
  the way Anki does it: cards come back sooner when they're hard, and
  later and later as they're learnt.

    * **Decks** - a panel for each, with how many cards are due and new
      today. Tap one to study it.
    * **Studying** - the card's front, as big as it fits; Show answer
      turns it over, and Again, Good or Easy says how it went. Pictures
      on the cards show, and sounds play (and again with the speaker).
    * **Done** - when nothing's left for today.

  Decks are in `NervesPhone.Flashcards.Library`, state in
  `NervesPhone.Apps.Flashcards.State`.
  """

  @behaviour NervesPhone.App

  use Emerge.UI
  import NervesPhone.UI.Theme
  import Solve.Lookup, only: [solve: 2, event: 3]

  @app NervesPhone.State

  @impl NervesPhone.App
  def name, do: "Flash Cards"

  @impl NervesPhone.App
  def icon, do: :cards

  @impl NervesPhone.App
  def tile, do: {{72, 184, 120}, {24, 128, 112}}

  @impl NervesPhone.App
  def controllers, do: [[name: :flashcards, module: NervesPhone.Apps.Flashcards.State]]

  @impl NervesPhone.App
  def opened, do: Solve.dispatch(@app, :flashcards, :opened, nil)

  @impl NervesPhone.App
  def closed, do: Solve.dispatch(@app, :flashcards, :decks, nil)

  @impl NervesPhone.App
  def toolbar, do: []

  @impl NervesPhone.App
  def status do
    cards = solve(@app, :flashcards)

    case {cards.page, cards.session} do
      {:study, %{} = s} -> "#{s.name} · #{s.left} left"
      {:done, %{} = s} -> "#{s.name} · done for today"
      _ when cards.loading -> "Getting the cards ready…"
      _ -> "Pick a deck"
    end
  end

  @impl NervesPhone.App
  def back do
    cards = solve(@app, :flashcards)
    if cards.page != :decks, do: event(cards, :decks, nil)
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

  defp decks(%{decks: [], loading: true}), do: message(["Getting the cards ready…"])

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

  defp deck(cards, deck) do
    counts =
      if deck.due + deck.new == 0 do
        [
          row([spacing(s(4))], [
            el([center_y()], icon(:check, 12, c(:acc_from))),
            el([Font.size(s(12)), Font.color(c(:acc_from))], text("Done for today"))
          ])
        ]
      else
        [
          if(deck.due > 0, do: badge("#{deck.due} to review", c(:acc_from)), else: none()),
          if(deck.new > 0, do: badge("#{deck.new} new", color_rgb(24, 128, 112)), else: none())
        ]
      end

    Input.button(
      [
        key({:deck, deck.id}),
        width(fill()),
        padding(s(12)),
        Border.rounded(s(3)),
        Border.width(1),
        Border.color(c(:text, 0.12)),
        Background.color(vgrad(:s0, :s1)),
        Event.on_press(event(cards, :study, deck.id)),
        Interactive.mouse_down(pressed())
      ] ++ raised(),
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
          row([spacing(s(6))], [
            el(
              [center_y(), Font.size(s(11)), Font.light(), Font.color(c(:dim))],
              text("#{deck.total} cards")
            )
            | counts
          ])
        ])
      ])
    )
  end

  defp badge(label, color) do
    el(
      [
        center_y(),
        padding_xy(s(6), s(2)),
        Border.rounded(s(8)),
        Background.color(color),
        Font.size(s(11)),
        Font.medium(),
        Font.color(c(:white))
      ],
      text(label)
    )
  end

  # ---------- Studying ----------

  # The card as a sheet of paper filling the screen, and the buttons
  # under it.
  defp study(cards, session) do
    blocks = if session.revealed, do: session.card.back, else: session.card.front
    sounds? = Enum.any?(blocks, &match?({:sound, _}, &1))
    shown = Enum.reject(blocks, &match?({:sound, _}, &1))

    content =
      cond do
        # Only a sound: a big button to hear it again.
        shown == [] ->
          el([center_x(), center_y()], round_button(:volume_3, event(cards, :replay, nil), 96))

        # Pictures share the height between them.
        Enum.any?(shown, &match?({:image, _}, &1)) ->
          column(
            [width(fill()), height(fill()), spacing(s(12))],
            Enum.map(shown, &block(&1, session.media_dir))
          )

        # Text sits together in the middle.
        true ->
          column(
            [width(fill()), center_y(), spacing(s(16))],
            Enum.map(shown, &block(&1, session.media_dir))
          )
      end

    replay =
      if sounds? and shown != [],
        do:
          el(
            [align_right(), align_top(), padding(s(8))],
            round_button(:volume_3, event(cards, :replay, nil), 44)
          ),
        else: none()

    sheet =
      el(
        [
          width(fill()),
          height(fill()),
          padding(s(16)),
          Border.rounded(s(4)),
          Border.width(1),
          Border.color(c(:text, 0.12)),
          Background.color(c(:white)),
          Nearby.in_front(replay)
        ] ++ raised(),
        content
      )

    column([width(fill()), height(fill()), padding(s(12)), spacing(s(12))], [
      sheet,
      answers(cards, session)
    ])
  end

  defp answers(cards, %{revealed: false}) do
    big_button("Show answer", event(cards, :reveal, nil), accent())
  end

  defp answers(cards, _session) do
    row([width(fill()), spacing(s(8))], [
      big_button(
        "Again",
        event(cards, :answer, :again),
        gradient([color_rgb(224, 96, 72), color_rgb(184, 48, 48)], 45)
      ),
      big_button("Good", event(cards, :answer, :good), accent()),
      big_button(
        "Easy",
        event(cards, :answer, :easy),
        gradient([color_rgb(72, 184, 120), color_rgb(24, 128, 112)], 45)
      )
    ])
  end

  defp big_button(label, on_press, background) do
    Input.button(
      [
        width(fill()),
        height(px(s(64))),
        Border.rounded(s(3)),
        Background.color(background),
        Font.size(s(18)),
        Font.semi_bold(),
        Font.color(c(:white)),
        Event.on_press(on_press),
        Interactive.mouse_down(pressed())
      ] ++ raised(),
      el([center_x(), center_y()], text(label))
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

  # Text as big as its length allows: a letter or a sum fills the card,
  # a sentence reads comfortably.
  defp block({:text, line}, _dir) do
    size =
      case String.length(line) do
        n when n <= 3 -> 96
        n when n <= 12 -> 44
        n when n <= 40 -> 28
        _ -> 18
      end

    paragraph(
      [
        width(fill()),
        Font.center(),
        Font.size(s(size)),
        Font.medium(),
        Font.color(c(:text))
      ],
      [text(line)]
    )
  end

  defp block({:image, name}, dir) do
    image([width(fill()), height(fill()), image_fit(:contain)], {:path, Path.join(dir, name)})
  end

  defp block(:divider, _dir) do
    el(
      [width(fill()), height(px(s(2))), Border.rounded(s(1)), Background.color(c(:text, 0.1))],
      none()
    )
  end

  # ---------- Done ----------

  defp done(cards, session) do
    lines =
      if session.studied == 0,
        do: ["Nothing to study here right now.", "Come back tomorrow for more."],
        else: [
          "Well done!",
          "#{session.studied} #{if session.studied == 1, do: "card", else: "cards"} studied. Come back tomorrow for more."
        ]

    column([width(fill()), height(fill()), padding(s(24)), spacing(s(16))], [
      el([center_x(), padding_xy(0, s(24))], tile({{240, 160, 48}, {208, 96, 32}}, :star, 96)),
      message(lines),
      el(
        [center_x()],
        button("Back to the decks", event(cards, :decks, nil), primary: true, height: 52)
      )
    ])
  end
end
