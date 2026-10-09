defmodule NervesPhone.Flashcards.Progress do
  @moduledoc """
  How each flash card's going (`NervesPhone.Flashcards.Scheduler`'s
  state for it), in `state_dir/flashcards/progress.jsonl`.

  Cards are known by their note's GUID and their number in it, as Anki
  knows them, so progress survives a deck being updated or copied again.
  Like `NervesPhone.Kids.History`, the file only grows, a line each
  answer, and the last line for a card wins; it's rewritten with a line a
  card at start once old lines outnumber cards.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every card's state, by key."
  @spec all() :: %{String.t() => map()}
  def all, do: GenServer.call(__MODULE__, :all)

  @doc "Records a card's new state."
  @spec put(String.t(), map()) :: :ok
  def put(key, state), do: GenServer.call(__MODULE__, {:put, key, state})

  @impl true
  def init(_opts) do
    {cards, lines} = load()
    if lines > 2 * map_size(cards) + 50, do: compact(cards)
    {:ok, cards}
  end

  @impl true
  def handle_call(:all, _from, cards), do: {:reply, cards, cards}

  def handle_call({:put, key, state}, _from, cards) do
    append([line(key, state)])
    {:reply, :ok, Map.put(cards, key, state)}
  end

  defp path, do: Path.join([NervesPhone.state_dir(), "flashcards", "progress.jsonl"])

  defp line(key, state), do: [JSON.encode!(Map.put(state, "key", key)), "\n"]

  defp load do
    case File.read(path()) do
      {:ok, data} ->
        lines = String.split(data, "\n", trim: true)

        cards =
          Enum.reduce(lines, %{}, fn line, cards ->
            case JSON.decode(line) do
              {:ok, %{"key" => key} = state} -> Map.put(cards, key, Map.delete(state, "key"))
              # A line cut off by a power cut.
              _bad -> cards
            end
          end)

        {cards, length(lines)}

      {:error, :enoent} ->
        {%{}, 0}

      {:error, reason} ->
        Logger.error("Couldn't read the flash card progress: #{:file.format_error(reason)}")
        {%{}, 0}
    end
  end

  defp append(data) do
    File.mkdir_p(Path.dirname(path()))

    case File.write(path(), data, [:append, :sync]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Couldn't write the flash card progress: #{:file.format_error(reason)}")
    end
  end

  defp compact(cards) do
    tmp = path() <> ".tmp"
    data = Enum.map(cards, fn {key, state} -> line(key, state) end)

    with :ok <- File.write(tmp, data, [:sync]),
         :ok <- File.rename(tmp, path()) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Couldn't compact the flash card progress: #{:file.format_error(reason)}")
    end
  end
end
