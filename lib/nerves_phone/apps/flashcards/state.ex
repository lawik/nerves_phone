defmodule NervesPhone.Apps.Flashcards.State do
  @moduledoc """
  The Flash Cards app's controller: the decks, and the one being studied.

  Pages are `:decks`, `:study` and `:done`. Opening the app reads the
  decks (`NervesPhone.Flashcards.Library`) in a task, with how many cards
  each has due and new today; not before, as reading new decks takes a
  moment.

  Picking a deck (`:study`) marks it as `opening` at once, and nothing
  else can be picked meanwhile; the cards are dealt in a task, and the
  first one shows once that's done, and not sooner than `@opening_ms`
  after the pick, so the choice is seen to be taken. Back (`:decks`)
  cancels it.

  Dealing takes the cards due now (or within the next 20 minutes, as Anki
  does), then new ones, up to a number of new cards a day (`config
  :nerves_phone, :flashcards, new_per_day: 10`). Each card is asked as a
  multiple-choice question (`NervesPhone.Flashcards.Quiz`), and the pick
  grades it: right is Good, wrong is Again, scheduled by
  `NervesPhone.Flashcards.Scheduler` and saved in
  `NervesPhone.Flashcards.Progress`. After a right pick the next card
  comes by itself; after a wrong one, the right answer shows until
  `:next`. A card that's still being learnt comes round again in the same
  session: a few cards on if it was wrong, at the end if it was right.

  A deck with nothing to study today is dealt whole, shuffled, as
  practice: picks don't change when its cards come back, and a wrong card
  still comes round again.

  A round's score is how many cards were right the first time they came
  up, and a perfect round of the whole deck is timed, from the first card
  showing to the last pick; `NervesPhone.Flashcards.Results` keeps the
  last score and the fastest time. Nothing is shown counting while
  playing: the time is only there to beat, for those who want to.

  The prompt's sounds play when a card shows, and again with `:replay`;
  the answer's play when it's picked.
  """

  use Solve.Controller,
    events: [:opened, :study, :pick, :next, :replay, :decks]

  alias NervesPhone.Flashcards.{Library, Progress, Quiz, Results, Scheduler, Sound}

  # Cards due within this long are dealt now.
  @learn_ahead_s 20 * 60

  # A wrong card comes back this many cards on.
  @again_after 3

  # A picked deck shows as opening at least this long.
  @opening_ms 400

  # A right answer shows this long before the next card.
  @right_ms 1_200

  @impl Solve.Controller
  def init(_params, _dependencies) do
    %{page: :decks, loading: true, decks: [], data: %{}, opening: nil, session: nil}
  end

  @impl Solve.Controller
  def expose(state, _dependencies, _params) do
    %{
      page: state.page,
      loading: state.loading,
      decks: state.decks,
      opening: state.opening && state.opening.id,
      session:
        state.session &&
          state.session
          |> Map.take([
            :deck,
            :name,
            :card,
            :question,
            :picked,
            :studied,
            :right,
            :media_dir,
            :practice,
            :result
          ])
          |> Map.put(:left, length(state.session.queue) + if(state.session.card, do: 1, else: 0))
          |> Map.put(:marks, Enum.reverse(state.session.marks))
    }
  end

  def opened(_payload, %{page: :study} = state), do: state

  def opened(_payload, state) do
    send(self(), :load)
    %{state | page: :decks, loading: true, opening: nil}
  end

  def decks(_payload, state) do
    Sound.stop()
    opened(nil, %{state | session: nil, page: :decks})
  end

  def study(id, %{page: :decks, opening: nil} = state) do
    case state.data do
      %{^id => deck} ->
        controller = self()

        Task.Supervisor.start_child(NervesPhone.TaskSupervisor, fn ->
          send(controller, {:dealt, id, deal(deck, Progress.all(), DateTime.utc_now(), tz())})
        end)

        %{state | opening: %{id: id, at: System.monotonic_time(:millisecond)}}

      _unknown ->
        state
    end
  end

  def study(_id, state), do: state

  def pick(index, %{session: %{card: %{}, picked: nil} = s} = state) when is_integer(index) do
    %{card: card, question: question} = s
    right? = index == question.correct
    rating = if right?, do: :good, else: :again

    {progress, queue} =
      if s.practice do
        {s.progress, if(right?, do: s.queue, else: List.insert_at(s.queue, @again_after, card))}
      else
        now = DateTime.utc_now()
        card_state = Scheduler.answer(s.progress[card.key], rating, now, tz())
        :ok = Progress.put(card.key, card_state)

        queue =
          if Scheduler.learning?(card_state) and
               card_state["due"] <= DateTime.to_unix(now) + @learn_ahead_s do
            at = if right?, do: length(s.queue), else: @again_after
            List.insert_at(s.queue, at, card)
          else
            s.queue
          end

        {Map.put(s.progress, card.key, card_state), queue}
      end

    # Only the first time a card comes up counts for the score.
    {marks, seen} =
      if MapSet.member?(s.seen, card.key),
        do: {s.marks, s.seen},
        else: {[right? | s.marks], MapSet.put(s.seen, card.key)}

    play(question.answer_sounds, s.media_dir)
    if right?, do: Process.send_after(self(), {:advance, card.key, s.studied}, @right_ms)

    %{
      state
      | session: %{
          s
          | progress: progress,
            queue: queue,
            marks: marks,
            seen: seen,
            last_at: System.monotonic_time(:millisecond),
            picked: index,
            studied: s.studied + 1,
            right: s.right + if(right?, do: 1, else: 0)
        }
    }
  end

  def pick(_index, state), do: state

  def next(_payload, %{session: %{picked: picked}} = state) when picked != nil,
    do: next_card(state)

  def next(_payload, state), do: state

  def replay(_payload, %{session: %{card: %{}} = s} = state) do
    play(s.question.sounds, s.media_dir)
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
    results = Results.all()
    now = DateTime.utc_now()
    tz = tz()

    summaries =
      for deck <- decks do
        {due, new} = counts(deck, progress, now, tz)
        result = results[deck.id]

        %{
          id: deck.id,
          name: deck.name,
          parent: deck.parent,
          total: length(deck.cards),
          due: due,
          new: new,
          last: result && {result.right, result.cards},
          best_ms: result && result.best_ms
        }
      end

    %{state | loading: false, decks: summaries, data: Map.new(decks, &{&1.id, &1})}
  end

  # The cards are dealt: start, once the deck's been seen opening long
  # enough. Unless the opening's been cancelled meanwhile.
  def handle_info({:dealt, id, queue}, %{opening: %{id: id, at: at}} = state) do
    case at + @opening_ms - System.monotonic_time(:millisecond) do
      wait when wait > 0 ->
        Process.send_after(self(), {:dealt, id, queue}, wait)
        state

      _now ->
        deck = state.data[id]

        {queue, practice?} =
          if queue == [], do: {Enum.shuffle(deck.cards), true}, else: {queue, false}

        session = %{
          deck: id,
          name: deck.name,
          media_dir: deck.media_dir,
          cards: deck.cards,
          progress: Progress.all(),
          queue: queue,
          card: nil,
          question: nil,
          picked: nil,
          studied: 0,
          right: 0,
          practice: practice?,
          marks: [],
          seen: MapSet.new(),
          started_at: System.monotonic_time(:millisecond),
          last_at: nil,
          result: nil
        }

        next_card(%{state | opening: nil, session: session})
    end
  end

  def handle_info({:dealt, _stale, _queue}, state), do: state

  # After a right answer, unless something's moved on since (the same
  # card back again, unanswered, isn't the one answered).
  def handle_info(
        {:advance, key, studied},
        %{session: %{card: %{key: key}, studied: now_studied, picked: picked}} = state
      )
      when now_studied == studied + 1 and picked != nil,
      do: next_card(state)

  def handle_info({:advance, _key, _studied}, state), do: state

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

  defp next_card(%{session: %{queue: [card | queue]} = s} = state) do
    question = Quiz.question(card, s.cards)
    play(question.sounds, s.media_dir)

    %{
      state
      | page: :study,
        session: %{s | card: card, queue: queue, question: question, picked: nil}
    }
  end

  defp next_card(%{session: s} = state) do
    Sound.stop()
    s = %{s | card: nil, question: nil, picked: nil, result: record(s)}
    %{state | page: :done, session: s}
  end

  # The round's score, and its time if it was all right first time and
  # had every card in the deck.
  defp record(%{marks: []}), do: nil

  defp record(s) do
    right = Enum.count(s.marks, & &1)
    cards = length(s.marks)
    perfect? = right == cards and cards == length(s.cards)
    ms = if perfect?, do: Kernel.max(s.last_at - s.started_at, 1)
    {_result, best?} = Results.record(s.deck, right, cards, ms)
    %{right: right, cards: cards, ms: ms, best: best?}
  end

  defp play([], _dir), do: Sound.stop()
  defp play(names, dir), do: names |> Enum.map(&Path.join(dir, &1)) |> Sound.play()

  defp new_per_day,
    do: Application.get_env(:nerves_phone, :flashcards, []) |> Keyword.get(:new_per_day, 10)

  defp tz, do: NervesPhone.Schedule.get()["timezone"] || "Etc/UTC"
end
