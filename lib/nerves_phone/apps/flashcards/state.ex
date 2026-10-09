defmodule NervesPhone.Apps.Flashcards.State do
  @moduledoc """
  The Flash Cards app's controller: the decks, and the one being studied.

  Pages are `:decks`, `:study` and `:done`. Opening the app reads the
  decks (`NervesPhone.Flashcards.Library`) in a task, with how many cards
  each has due and new today; not before, as reading new decks takes a
  moment.

  Studying a deck deals the cards due now (or within the next 20
  minutes, as Anki does), then new ones, up to a number of new cards a
  day (`config :nerves_phone, :flashcards, new_per_day: 10`). A card shows
  its front; Reveal shows the back, and an answer (`:again`, `:good` or
  `:easy`) schedules it (`NervesPhone.Flashcards.Scheduler`), saves that
  (`NervesPhone.Flashcards.Progress`) and moves on. A card that's still
  being learnt comes round again in the same session: after a few cards
  for Again, at the end for Good. Sounds on the side showing play by
  themselves, and again with `:replay`.
  """

  use Solve.Controller,
    events: [:opened, :study, :reveal, :answer, :replay, :decks]

  alias NervesPhone.Flashcards.{Library, Progress, Scheduler, Sound}

  # Cards due within this long are dealt now.
  @learn_ahead_s 20 * 60

  # Again puts a card back this many cards on.
  @again_after 3

  @impl Solve.Controller
  def init(_params, _dependencies) do
    %{page: :decks, loading: true, decks: [], data: %{}, session: nil}
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{
      page: state.page,
      loading: state.loading,
      decks: state.decks,
      session:
        state.session &&
          state.session
          |> Map.take([:deck, :name, :card, :revealed, :studied, :media_dir])
          |> Map.put(:left, length(state.session.queue) + if(state.session.card, do: 1, else: 0))
    }
  end

  def opened(_payload, %{page: :study} = state), do: state

  def opened(_payload, state) do
    send(self(), :load)
    %{state | page: :decks, loading: true}
  end

  def decks(_payload, state) do
    Sound.stop()
    opened(nil, %{state | session: nil})
  end

  def study(id, state) do
    case state.data do
      %{^id => deck} ->
        now = DateTime.utc_now()
        progress = Progress.all()
        queue = deal(deck, progress, now, tz())

        session = %{
          deck: id,
          name: deck.name,
          media_dir: deck.media_dir,
          progress: progress,
          queue: queue,
          card: nil,
          revealed: false,
          studied: 0
        }

        next_card(%{state | session: session})

      _unknown ->
        state
    end
  end

  def reveal(_payload, %{session: %{card: %{}} = session} = state) do
    session = %{session | revealed: true}
    play(session)
    %{state | session: session}
  end

  def reveal(_payload, state), do: state

  def answer(rating, %{session: %{card: %{} = card, revealed: true} = s} = state)
      when rating in [:again, :good, :easy] do
    now = DateTime.utc_now()
    card_state = Scheduler.answer(s.progress[card.key], rating, now, tz())
    :ok = Progress.put(card.key, card_state)

    queue =
      if Scheduler.learning?(card_state) and
           card_state["due"] <= DateTime.to_unix(now) + @learn_ahead_s do
        at = if rating == :again, do: @again_after, else: length(s.queue)
        List.insert_at(s.queue, at, card)
      else
        s.queue
      end

    session = %{
      s
      | progress: Map.put(s.progress, card.key, card_state),
        queue: queue,
        studied: s.studied + 1
    }

    next_card(%{state | session: session})
  end

  def answer(_rating, state), do: state

  def replay(_payload, %{session: %{card: %{}} = session} = state) do
    play(session)
    state
  end

  def replay(_payload, state), do: state

  def handle_info(:load, state) do
    controller = self()

    Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
      send(controller, {:decks, Library.decks()})
    end)

    state
  end

  def handle_info({:decks, decks}, state) do
    progress = Progress.all()
    now = DateTime.utc_now()
    tz = tz()

    summaries =
      for deck <- decks do
        {due, new} = counts(deck, progress, now, tz)

        %{
          id: deck.id,
          name: deck.name,
          parent: deck.parent,
          total: length(deck.cards),
          due: due,
          new: new
        }
      end

    %{state | loading: false, decks: summaries, data: Map.new(decks, &{&1.id, &1})}
  end

  def handle_info(_message, state), do: state

  # The cards to study now: those due, soonest first, then new ones.
  defp deal(deck, progress, now, tz) do
    {due, new} = split(deck, progress, now, tz)
    Enum.sort_by(due, &progress[&1.key]["due"]) ++ new
  end

  defp counts(deck, progress, now, tz) do
    {due, new} = split(deck, progress, now, tz)
    {length(due), length(new)}
  end

  defp split(deck, progress, now, tz) do
    soon = DateTime.add(now, @learn_ahead_s)
    today = now |> Scheduler.today(tz) |> Date.to_iso8601()

    {seen, unseen} = Enum.split_with(deck.cards, &Map.has_key?(progress, &1.key))
    due = Enum.filter(seen, &Scheduler.due?(progress[&1.key], soon))
    introduced = Enum.count(seen, &(progress[&1.key]["first"] == today))

    {due, Enum.take(unseen, Kernel.max(new_per_day() - introduced, 0))}
  end

  defp next_card(%{session: %{queue: [card | queue]} = session} = state) do
    session = %{session | card: card, queue: queue, revealed: false}
    play(session)
    %{state | page: :study, session: session}
  end

  defp next_card(%{session: session} = state) do
    Sound.stop()
    %{state | page: :done, session: %{session | card: nil, revealed: false}}
  end

  # The sounds on the side showing: on the back, those after the divider
  # (the front's were heard already).
  defp play(%{card: card, revealed: revealed, media_dir: dir}) do
    blocks =
      if revealed do
        case Enum.split_while(card.back, &(&1 != :divider)) do
          {_front, [:divider | answer]} -> answer
          {back, []} -> back
        end
      else
        card.front
      end

    case for({:sound, name} <- blocks, do: Path.join(dir, name)) do
      [] -> Sound.stop()
      paths -> Sound.play(paths)
    end
  end

  defp new_per_day,
    do: Application.get_env(:nerves_phone, :flashcards, []) |> Keyword.get(:new_per_day, 10)

  defp tz, do: NervesPhone.Schedule.get()["timezone"] || "Etc/UTC"
end
