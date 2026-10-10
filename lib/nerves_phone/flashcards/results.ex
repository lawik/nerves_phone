defmodule NervesPhone.Flashcards.Results do
  @moduledoc """
  How each deck's last round went, and its fastest perfect round, in
  `state_dir/flashcards/results.json`.

  A round's score is how many of its cards were right the first time
  they came up, out of how many came up. A perfect round of the whole
  deck has a time, and the fastest is kept; nothing else is timed.

  Only `NervesPhone.Apps.Flashcards.State` writes it, so it's plain
  functions over the file rather than a process.
  """

  require Logger

  @type result :: %{
          right: non_neg_integer(),
          cards: non_neg_integer(),
          best_ms: pos_integer() | nil
        }

  @doc "Every deck's result, by deck id."
  @spec all() :: %{String.t() => result()}
  def all do
    with {:ok, data} <- File.read(path()),
         {:ok, %{} = decks} <- JSON.decode(data) do
      for {id, %{"right" => right, "cards" => cards} = r} <- decks,
          into: %{},
          do: {id, %{right: right, cards: cards, best_ms: r["best_ms"]}}
    else
      {:error, :enoent} ->
        %{}

      error ->
        Logger.error("Couldn't read the flash card results: #{inspect(error)}")
        %{}
    end
  end

  @doc """
  Records a round of `deck`: `right` of `cards`, and its time if it was
  a perfect round of the whole deck. Returns the deck's result, and
  whether the time is its fastest yet.
  """
  @spec record(String.t(), non_neg_integer(), non_neg_integer(), pos_integer() | nil) ::
          {result(), boolean()}
  def record(deck, right, cards, ms) do
    results = all()
    best = get_in(results, [deck, :best_ms])
    best? = ms != nil and (best == nil or ms < best)
    result = %{right: right, cards: cards, best_ms: if(best?, do: ms, else: best)}
    write(Map.put(results, deck, result))
    {result, best?}
  end

  defp path, do: Path.join([NervesPhone.state_dir(), "flashcards", "results.json"])

  defp write(results) do
    tmp = path() <> ".tmp"

    data =
      Map.new(results, fn {id, r} ->
        {id, %{"right" => r.right, "cards" => r.cards, "best_ms" => r.best_ms}}
      end)

    with :ok <- File.mkdir_p(Path.dirname(path())),
         :ok <- File.write(tmp, JSON.encode!(data), [:sync]),
         :ok <- File.rename(tmp, path()) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Couldn't write the flash card results: #{:file.format_error(reason)}")
    end
  end
end
