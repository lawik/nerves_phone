defmodule NervesPhone.Flashcards.Quiz do
  @moduledoc """
  A card as a multiple-choice question, so children answer by picking
  rather than grading themselves: the card's prompt, and up to four
  choices, the card's answer among answers from other cards in the deck.

  The answer is what's after the divider on the back (`<hr id=answer>`),
  or what the back adds to the front. Choices show what can be seen (text
  and pictures). The prompt's sounds (`sounds`) play with it, and the
  answer's (`answer_sounds`) once it's picked.

    * Most cards ask their front and offer answers.
    * A card whose answer is only a sound (a letter's picture on the front,
      how it's said on the back) is asked the other way round: the sound
      plays, and the choices are fronts, so it's "which letter is this?".
    * A number's wrong choices are numbers near it (and the deck's other
      answers near it), so a sum isn't solved by ruling out the odd ones.

  Choices are distinct as they'd show, so two choices never look the same.
  """

  alias NervesPhone.Flashcards.{Apkg, Html}

  @type t :: %{
          prompt: [Html.block()],
          choices: [[Html.block()]],
          correct: non_neg_integer(),
          sounds: [String.t()],
          answer_sounds: [String.t()]
        }

  @choices 4

  @doc "The question for `card`, with wrong choices from `cards` (its deck)."
  @spec question(Apkg.card(), [Apkg.card()]) :: t()
  def question(card, cards) do
    answer = answer(card)
    sound_only? = visible(answer) == []

    {prompt, side} =
      if sound_only?,
        do: {answer, &visible(&1.front)},
        else: {card.front, &visible(answer(&1))}

    right = side.(card)

    others =
      cards
      |> Stream.reject(&(&1.key == card.key))
      |> Stream.map(side)
      |> Stream.reject(&(&1 == [] or &1 == right))
      |> Enum.uniq()

    choices = [right | wrong(right, others)] |> Enum.shuffle()

    %{
      prompt: prompt,
      choices: choices,
      correct: Enum.find_index(choices, &(&1 == right)),
      sounds: sounds(prompt),
      answer_sounds: if(sound_only?, do: [], else: sounds(answer))
    }
  end

  @doc """
  What a card's back adds: after the divider, or what follows the front.
  """
  @spec answer(Apkg.card()) :: [Html.block()]
  def answer(card) do
    case Enum.split_while(card.back, &(&1 != :divider)) do
      {_front, [:divider | answer]} -> answer
      {back, []} -> back -- card.front
    end
  end

  defp sounds(blocks), do: for({:sound, name} <- blocks, do: name)

  defp visible(blocks),
    do: Enum.filter(blocks, &match?({kind, _} when kind in [:text, :image], &1))

  defp wrong(right, others) do
    case number(right) do
      {:ok, n} -> near(n, others)
      :error -> others |> Enum.shuffle() |> Enum.take(@choices - 1)
    end
  end

  defp number([{:text, text}]) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp number(_blocks), do: :error

  # Numbers close to n, from the deck and either side of it, three of the
  # closest few.
  defp near(n, others) do
    from_deck = for blocks <- others, {:ok, m} <- [number(blocks)], do: m

    (from_deck ++ [n - 1, n + 1, n - 2, n + 2, n - 10, n + 10])
    |> Enum.uniq()
    |> Enum.reject(&(&1 < 0 or &1 == n))
    |> Enum.sort_by(&abs(&1 - n))
    |> Enum.take(6)
    |> Enum.shuffle()
    |> Enum.take(@choices - 1)
    |> Enum.map(&[{:text, Integer.to_string(&1)}])
  end
end
