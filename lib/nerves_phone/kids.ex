defmodule NervesPhone.Kids do
  @moduledoc """
  What the children are offered to watch, from the videos sorted with
  phone_remote, the watch history (`NervesPhone.Kids.History`) and the
  rules (`NervesPhone.Kids.Rules`, applied by `NervesPhone.Kids.Offers`).

  Both offerings are kept in `state_dir/kids/offers.json`, so neither
  backing out nor restarting the phone deals new ones, and the
  entertainment offering is still there after a spell of education.
  """

  alias NervesPhone.Kids.{History, Offers, Rules}
  alias NervesPhone.Video.Library

  @doc """
  The offering showing now: its kind, and its videos in their slots'
  order. It's brought up to date first (`Offers.refresh/5`) and saved.
  """
  @spec offers() :: %{showing: String.t(), videos: [Offers.video()]}
  def offers do
    rules = Rules.get()
    history = History.all()
    videos = sorted_videos()
    showing = Offers.showing(history, rules)

    saved = read_saved()
    slots = Offers.refresh(Map.get(saved, showing, []), showing, videos, history, rules)
    if slots != Map.get(saved, showing), do: save(Map.put(saved, showing, slots))

    by_path = Map.new(videos, &{&1.path, &1})
    %{showing: showing, videos: Enum.map(slots, &by_path[&1.path])}
  end

  @doc """
  Where things stand, for phone_remote or a remote shell: the rules, the
  education rule's balance, the shows resting, and the last few watches.
  """
  @spec summary() :: map()
  def summary do
    rules = Rules.get()
    history = History.all()

    %{
      rules: rules,
      balance: Offers.balance(history, rules),
      showing: Offers.showing(history, rules),
      offerings: read_saved(),
      resting_shows: history |> Offers.resting_shows(rules) |> MapSet.to_list(),
      recent: Enum.take(history, -10),
      watches: length(history)
    }
  end

  @doc "Every sorted video on the phone."
  @spec sorted_videos() :: [Offers.video()]
  def sorted_videos do
    for found <- Library.videos(),
        video = Offers.video(found),
        video.kind in ["education", "entertainment"],
        do: video
  end

  defp path, do: Path.join([NervesPhone.state_dir(), "kids", "offers.json"])

  # %{kind => [slot]}
  defp read_saved do
    with {:ok, json} <- File.read(path()),
         {:ok, %{} = saved} <- JSON.decode(json) do
      for {kind, slots} <- saved, kind in Offers.kinds(), is_list(slots), into: %{} do
        {kind, for(%{"path" => path, "after" => n} <- slots, do: %{path: path, after: n})}
      end
    else
      _none -> %{}
    end
  end

  defp save(offerings) do
    File.mkdir_p(Path.dirname(path()))
    tmp = path() <> ".tmp"
    with :ok <- File.write(tmp, JSON.encode!(offerings)), do: File.rename(tmp, path())
  end
end
