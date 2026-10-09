defmodule NervesPhone.Flashcards.Library do
  @moduledoc """
  The flash card decks on the phone: Anki packages (`.apkg`) in the
  roots (`config :nerves_phone, :flashcards, roots: [...]`, `/data/flashcards`
  by default), and the ones that come with the phone in
  `priv/flashcards`. Copy a deck from AnkiWeb or Anki into a root and it
  shows up the next time Flash Cards is opened.

  Each package is read once (`NervesPhone.Flashcards.Apkg`) into
  `state_dir/flashcards/decks/<id>`: its cards as a term, and its media
  as files, where the screen and the speaker can get at them. The id
  follows the file's path, size and time, so a changed file is read
  again; what's no longer there is cleared away.

  A package can hold several decks (`Maths::Addition`,
  `Maths::Subtraction`); each with cards is a deck here.
  """

  require Logger

  alias NervesPhone.Flashcards.Apkg

  @type deck :: %{
          id: String.t(),
          name: String.t(),
          parent: String.t() | nil,
          media_dir: Path.t(),
          cards: [Apkg.card()]
        }

  @doc "Where packages are looked for."
  @spec roots() :: [Path.t()]
  def roots do
    configured =
      Application.get_env(:nerves_phone, :flashcards, [])[:roots] || ["/data/flashcards"]

    configured ++ [Application.app_dir(:nerves_phone, "priv/flashcards")]
  end

  @doc "Where packages are read into; their media are shown from here."
  @spec cache_dir() :: Path.t()
  def cache_dir, do: Path.join([NervesPhone.state_dir(), "flashcards", "decks"])

  @doc "Every deck with cards, by name."
  @spec decks() :: [deck()]
  def decks do
    packages = for root <- roots(), path <- Path.wildcard(Path.join(root, "*.apkg")), do: path
    ids = Map.new(packages, &{&1, id(&1)})

    clear_stale(Map.values(ids))

    packages
    |> Enum.flat_map(fn path -> decks(path, ids[path]) end)
    |> Enum.sort_by(&{natural(&1.parent || ""), natural(&1.name)})
  end

  # Numbers in names by their value, so "2:ans tabell" comes before "10:ans".
  defp natural(name) do
    ~r/\d+/
    |> Regex.split(name, include_captures: true)
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {n, ""} -> {0, n}
        _ -> {1, part}
      end
    end)
  end

  defp decks(path, id) do
    dir = Path.join(cache_dir(), id)

    case load(path, dir) do
      {:ok, cards} ->
        cards
        |> Enum.group_by(& &1.deck)
        |> Enum.map(fn {name, cards} ->
          parts = String.split(name, "::")

          %{
            id: "#{id}/#{name}",
            name: List.last(parts),
            parent: if(length(parts) > 1, do: parts |> Enum.drop(-1) |> Enum.join(" › ")),
            media_dir: Path.join(dir, "media"),
            cards: Enum.sort_by(cards, & &1.new_order)
          }
        end)

      {:error, reason} ->
        Logger.warning("Couldn't read the deck #{path}: #{inspect(reason)}")
        []
    end
  end

  # The cards, from the cache, or read into it.
  defp load(path, dir) do
    cards_file = Path.join(dir, "cards.etf")

    with {:error, _} <- File.read(cards_file) |> decode() do
      File.rm_rf(dir)

      with {:ok, package} <- Apkg.read(path),
           :ok <- Apkg.extract_media(path, package.media, Path.join(dir, "media")) do
        # Written last: a cache with cards in it is complete.
        File.write!(cards_file, :erlang.term_to_binary(package.cards))
        {:ok, package.cards}
      end
    end
  end

  defp decode({:ok, binary}) do
    {:ok, :erlang.binary_to_term(binary)}
  rescue
    ArgumentError -> {:error, :bad_cache}
  end

  defp decode(error), do: error

  defp clear_stale(ids) do
    case File.ls(cache_dir()) do
      {:ok, dirs} -> for dir <- dirs, dir not in ids, do: File.rm_rf(Path.join(cache_dir(), dir))
      {:error, _} -> :ok
    end
  end

  defp id(path) do
    stat = File.stat!(path, time: :posix)

    {Path.expand(path), stat.size, stat.mtime}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end
end
