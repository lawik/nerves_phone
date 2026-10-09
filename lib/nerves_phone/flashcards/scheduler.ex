defmodule NervesPhone.Flashcards.Scheduler do
  @moduledoc """
  When a card comes back, after it's been answered: Anki's SM-2, with
  three answers, as there are on the phone (Again, Good, Easy).

    * A new card is learnt in steps a few minutes apart (1 and 10
      minutes): Again goes back to the first step, Good to the next, and
      Good on the last step, or Easy on any, graduates it to reviews.
    * A review card comes back after its interval in days: Good multiplies
      the interval by the card's ease (2.5 to start with), Easy by more,
      and raises the ease. Again is a lapse: the ease drops, the interval
      halves, and the card is relearnt in a 10-minute step.

  Days start at 04:00 local time, as in Anki, so a review due "tomorrow"
  can be done first thing in the morning. A card's state is a map with
  string keys, kept as JSON by `NervesPhone.Flashcards.Progress`:

    * `"due"` - when it's next due (Unix seconds)
    * `"step"` - the learning step it's on, or nil when it's in review
    * `"ivl"` - its interval in days (0 while it's first learnt)
    * `"ease"`, `"reps"`, `"lapses"`
    * `"first"` - the day it was first seen (ISO 8601), for the daily
      limit of new cards
  """

  @type rating :: :again | :good | :easy
  @type state :: %{String.t() => term()}

  @steps [60, 600]
  @relearn_step 600
  @start_ease 2.5
  @min_ease 1.3
  @max_ivl 365
  @day_starts ~T[04:00:00]

  @doc "The state of a card after an answer `now`, from nil for a new card."
  @spec answer(state() | nil, rating(), DateTime.t(), String.t()) :: state()
  def answer(nil, rating, now, tz) do
    new = %{
      "step" => 0,
      "ivl" => 0,
      "ease" => @start_ease,
      "reps" => 0,
      "lapses" => 0,
      "first" => Date.to_iso8601(today(now, tz))
    }

    answer(new, rating, now, tz)
  end

  def answer(state, rating, now, tz) do
    state |> Map.update("reps", 1, &(&1 + 1)) |> next(rating, now, tz)
  end

  # Learning (step not nil), first time round (ivl 0) or relearning.
  defp next(%{"step" => step} = state, rating, now, tz) when is_integer(step) do
    relearning? = state["ivl"] > 0
    steps = if relearning?, do: [@relearn_step], else: @steps

    case rating do
      :again ->
        at_step(state, 0, hd(steps), now)

      :good when step + 1 < length(steps) ->
        at_step(state, step + 1, Enum.at(steps, step + 1), now)

      :good ->
        graduate(state, Kernel.max(state["ivl"], 1), now, tz)

      :easy ->
        graduate(state, if(relearning?, do: state["ivl"] + 1, else: 4), now, tz)
    end
  end

  defp next(%{"ivl" => ivl, "ease" => ease} = state, rating, now, tz) do
    case rating do
      :again ->
        state
        |> Map.merge(%{
          "lapses" => state["lapses"] + 1,
          "ease" => Kernel.max(@min_ease, ease - 0.2),
          "ivl" => Kernel.max(1, round(ivl * 0.5))
        })
        |> at_step(0, @relearn_step, now)

      :good ->
        graduate(state, Kernel.max(ivl + 1, round(ivl * ease)), now, tz)

      :easy ->
        state
        |> Map.put("ease", ease + 0.15)
        |> graduate(Kernel.max(ivl + 2, round(ivl * ease * 1.3)), now, tz)
    end
  end

  defp at_step(state, step, seconds, now),
    do: %{state | "step" => step} |> Map.put("due", DateTime.to_unix(now) + seconds)

  defp graduate(state, ivl, now, tz) do
    ivl = Kernel.min(ivl, @max_ivl)
    due = now |> today(tz) |> Date.add(ivl) |> day_start(tz)
    %{state | "step" => nil, "ivl" => ivl} |> Map.put("due", due)
  end

  @doc "Whether a card's due at `now`."
  @spec due?(state() | nil, DateTime.t()) :: boolean()
  def due?(nil, _now), do: false
  def due?(state, now), do: state["due"] <= DateTime.to_unix(now)

  @doc "Whether a card's being learnt (it'll be back in minutes, not days)."
  @spec learning?(state()) :: boolean()
  def learning?(state), do: is_integer(state["step"])

  @doc "The day it is `now` in `tz`, where days start at 04:00."
  @spec today(DateTime.t(), String.t()) :: Date.t()
  def today(now, tz) do
    local =
      case DateTime.shift_zone(now, tz) do
        {:ok, local} -> local
        {:error, _} -> now
      end

    local |> DateTime.add(-time_seconds(@day_starts)) |> DateTime.to_date()
  end

  defp day_start(date, tz) do
    case DateTime.new(date, @day_starts, tz) do
      {:ok, at} -> DateTime.to_unix(at)
      {:ambiguous, first, _} -> DateTime.to_unix(first)
      {:gap, _, after_gap} -> DateTime.to_unix(after_gap)
      {:error, _} -> date |> DateTime.new!(@day_starts) |> DateTime.to_unix()
    end
  end

  defp time_seconds(time), do: elem(Time.to_seconds_after_midnight(time), 0)
end
