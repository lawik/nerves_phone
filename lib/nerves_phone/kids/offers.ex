defmodule NervesPhone.Kids.Offers do
  @moduledoc """
  What's on offer, by the history and the rules
  (`NervesPhone.Kids.Rules`). No files here: `NervesPhone.Kids` brings the
  videos, history and saved offers.

  There are two offerings, kept apart: entertainment and education. Each
  is a row of slots, `:offers` of them, holding a video each. One is shown
  at a time:

    * **Education after entertainment.** Normally the entertainment
      offering shows. Once `:entertainment_limit_min` of entertainment has
      played, the education offering shows instead, until
      `:education_required_min` of education has played; then the
      entertainment offering is back as it was, and entertainment starts
      counting from zero again. 0 in either turns this off (and the
      education offering never shows). A video that's playing when the
      limit's reached plays on to its end (or until it's stopped).
    * **A watched video makes room for one new one.** When a slot's video
      has been fully watched (`:fully_watched_pct` of its length actually
      played) since it was offered, that slot gets a new video and the
      others stay. So does a slot whose video has gone, or been sorted into
      the other kind. A video watched only partly stays on offer.
    * **Something else first.** A new video isn't from a show among the
      last `:show_cooldown` things watched, nor from a show already on
      offer if there's any other choice. From a show, the episode watched the
      fewest times comes first, at random between equals.

  Watched always means fully watched: stopping a video early doesn't
  replace it, rest its show or count as a play of it. The minutes it
  played do count towards the education rule.

  If nothing fits a slot, it's left out, so fewer videos show, until
  something else has been watched. But an offering is never left empty
  for the show rule alone, as then nothing could be watched to move it on
  (with only one show of a kind, say): the resting shows are offered
  then.

  A video's show is its series from its metadata (an SVT programme, a
  YouTube channel), or else its folder.
  """

  @kinds ["entertainment", "education"]

  @type video :: %{
          path: Path.t(),
          title: String.t(),
          series: String.t(),
          kind: String.t() | nil,
          duration_s: number() | nil,
          thumbnail: Path.t() | nil
        }

  @typedoc """
  A slot of an offering: its video, and how many history entries there
  were when it was offered (watches after that count towards replacing it).
  """
  @type slot :: %{path: Path.t(), after: non_neg_integer()}

  @type balance :: %{
          only: String.t() | nil,
          entertainment_s: non_neg_integer(),
          education_s: non_neg_integer()
        }

  @doc "The two offerings' kinds."
  def kinds, do: @kinds

  @doc "A video from `NervesPhone.Video.Library.videos/0`, as offers use it."
  @spec video(map()) :: video()
  def video(%{path: path, folder: folder} = found) do
    meta = found[:meta] || %{}

    %{
      path: path,
      title: meta["title"] || Path.rootname(Path.basename(path)),
      series: meta["series"] || folder,
      kind: meta["kind"],
      duration_s: meta["duration"],
      thumbnail: meta["thumbnail"] && Path.join(Path.dirname(path), meta["thumbnail"])
    }
  end

  @doc "Which offering shows after `history`."
  @spec showing([map()], map()) :: String.t()
  def showing(history, rules), do: balance(history, rules).only || "entertainment"

  @doc """
  Where the education rule stands after `history`: `:only` is
  `"education"` while the education offering shows, with the seconds of
  entertainment counted so far, or of education counted while it's
  required.
  """
  @spec balance([map()], map()) :: balance()
  def balance(history, rules) do
    limit = rules.entertainment_limit_min * 60
    required = rules.education_required_min * 60

    Enum.reduce(history, %{only: nil, entertainment_s: 0, education_s: 0}, fn entry, acc ->
      case {acc.only, entry.kind} do
        _rule_off when limit == 0 or required == 0 ->
          acc

        {nil, "entertainment"} ->
          seconds = acc.entertainment_s + entry.watched_s

          if seconds >= limit,
            do: %{acc | only: "education", entertainment_s: seconds, education_s: 0},
            else: %{acc | entertainment_s: seconds}

        {"education", "education"} ->
          seconds = acc.education_s + entry.watched_s

          if seconds >= required,
            do: %{only: nil, entertainment_s: 0, education_s: 0},
            else: %{acc | education_s: seconds}

        _other ->
          acc
      end
    end)
  end

  @doc "The watches that played their video through, oldest first."
  @spec watched([map()], map()) :: [map()]
  def watched(history, rules), do: Enum.filter(history, &fully_watched?(&1, rules))

  @doc "Whether a watch played (nearly) all of its video."
  @spec fully_watched?(map(), map()) :: boolean()
  def fully_watched?(%{duration_s: duration, watched_s: watched}, rules)
      when is_number(duration) and duration > 0,
      do: watched * 100 >= duration * rules.fully_watched_pct

  def fully_watched?(_entry, _rules), do: false

  @doc "The shows new offers can't come from now."
  @spec resting_shows([map()], map()) :: MapSet.t()
  def resting_shows(history, rules) do
    history
    |> watched(rules)
    |> Enum.take(-rules.show_cooldown)
    |> MapSet.new(& &1.series)
  end

  @doc """
  An offering of `kind` brought up to date: slots whose video has been
  fully watched since it was offered, or that no longer fit, get a new
  video; the rest stay where they are. Slots are added or dropped to make
  `rules.offers`. `shuffle` is for tests.
  """
  @spec refresh([slot()], String.t(), [video()], [map()], map(), ([term()] -> [term()])) ::
          [slot()]
  def refresh(slots, kind, videos, history, rules, shuffle \\ &Enum.shuffle/1) do
    case fill(slots, kind, videos, history, rules, shuffle, resting_shows(history, rules)) do
      [] -> fill(slots, kind, videos, history, rules, shuffle, MapSet.new())
      filled -> filled
    end
  end

  defp fill(slots, kind, videos, history, rules, shuffle, resting) do
    by_path = for video <- videos, video.kind == kind, into: %{}, do: {video.path, video}

    kept =
      slots
      |> Enum.take(rules.offers)
      |> Enum.map(fn slot -> if keep?(slot, by_path, history, rules), do: slot end)

    kept = kept ++ List.duplicate(nil, rules.offers - length(kept))

    context = %{
      candidates: Map.values(by_path),
      resting: resting,
      plays: history |> watched(rules) |> Enum.frequencies_by(& &1.path),
      shuffle: shuffle
    }

    # Fill the empty slots in order, each next to everything on offer so far.
    kept
    |> Enum.with_index()
    |> Enum.reduce(kept, fn
      {nil, at}, slots ->
        others = for %{path: path} <- slots, do: by_path[path]

        case new_video(context, others) do
          nil -> slots
          video -> List.replace_at(slots, at, %{path: video.path, after: length(history)})
        end

      _kept, slots ->
        slots
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp keep?(slot, by_path, history, rules) do
    Map.has_key?(by_path, slot.path) and
      not (history
           |> Enum.drop(slot.after)
           |> watched(rules)
           |> Enum.any?(&(&1.path == slot.path)))
  end

  defp new_video(context, others) do
    taken_paths = MapSet.new(others, & &1.path)
    taken_shows = MapSet.new(others, & &1.series)

    choices =
      context.candidates
      |> Enum.reject(
        &(MapSet.member?(taken_paths, &1.path) or MapSet.member?(context.resting, &1.series))
      )
      |> context.shuffle.()
      |> Enum.sort_by(&Map.get(context.plays, &1.path, 0))

    Enum.find(choices, &(not MapSet.member?(taken_shows, &1.series))) || List.first(choices)
  end
end
