defmodule NervesPhone.KidsTest do
  use ExUnit.Case

  alias NervesPhone.Kids.{History, Offers, Rules}

  setup do
    File.rm_rf!(Path.join(NervesPhone.state_dir(), "kids"))
    restart_history()
    :ok
  end

  defp restart_history do
    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, History)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, History)
  end

  # Every video is 10 minutes long; a watch of 10 minutes is a full one.
  defp watch(path, series, kind, minutes \\ 10),
    do: %{
      id: path,
      path: path,
      series: series,
      kind: kind,
      duration_s: 600,
      watched_s: round(minutes * 60)
    }

  defp videos do
    for {path, series, kind} <- [
          {"paw1", "Paw Patrol", "entertainment"},
          {"paw2", "Paw Patrol", "entertainment"},
          {"bluey1", "Bluey", "entertainment"},
          {"bluey2", "Bluey", "entertainment"},
          {"peppa1", "Peppa", "entertainment"},
          {"peppa2", "Peppa", "entertainment"},
          {"num1", "Numberblocks", "education"},
          {"num2", "Numberblocks", "education"},
          {"abc1", "Alphablocks", "education"},
          {"abc2", "Alphablocks", "education"},
          {"odd", "Odd", nil}
        ],
        do: %{path: path, title: path, series: series, kind: kind, duration_s: 600}
  end

  defp series(slots) do
    by_path = Map.new(videos(), &{&1.path, &1})
    for slot <- slots, do: by_path[slot.path].series
  end

  defp refresh(slots, kind, history, rules \\ Rules.defaults()),
    do: Offers.refresh(slots, kind, videos(), history, rules)

  describe "Rules" do
    test "defaults, changes kept on disk, and checked" do
      assert Rules.get() == Rules.defaults()
      assert {:ok, %{offers: 4, show_cooldown: 1}} = Rules.put(offers: 4)
      assert {:ok, %{offers: 4, show_cooldown: 2}} = Rules.put(%{"show_cooldown" => 2})
      assert %{offers: 4, show_cooldown: 2} = Rules.get()

      assert {:error, {:invalid, :offers, 0}} = Rules.put(offers: 0)

      assert {:error, {:invalid, :entertainment_limit_min, "x"}} =
               Rules.put(entertainment_limit_min: "x")

      assert {:error, {:invalid, :bedtime, 1}} = Rules.put(bedtime: 1)
      assert Rules.get().offers == 4

      assert {:ok, defaults} = Rules.reset()
      assert defaults == Rules.defaults()
    end
  end

  describe "Offers" do
    test "an offering is its kind's videos, one a show while there are enough" do
      slots = refresh([], "entertainment", [])
      assert length(slots) == 3
      assert slots |> series() |> Enum.sort() == ["Bluey", "Paw Patrol", "Peppa"]
      assert Enum.all?(slots, &(&1.after == 0))

      # More slots than shows: a second episode from some.
      rules = %{Rules.defaults() | offers: 5}
      assert refresh([], "entertainment", [], rules) |> Enum.uniq() |> length() == 5

      assert refresh([], "education", []) |> series() |> Enum.uniq() |> Enum.sort() ==
               ["Alphablocks", "Numberblocks"]
    end

    test "a fully watched video is replaced in its slot; the others stay" do
      [a, b, c] = slots = refresh([], "entertainment", [])
      watched = Enum.find(videos(), &(&1.path == b.path))

      history = [watch(watched.path, watched.series, "entertainment")]
      assert [^a, new, ^c] = refresh(slots, "entertainment", history)
      assert new.path != b.path and new.after == 1

      # Not from the show just watched (the third show's other episode
      # would be, so it's a second episode of a's or c's show).
      assert series([new]) != series([b])
    end

    test "a video stopped early stays, and doesn't rest its show" do
      [a, b, c] = slots = refresh([], "entertainment", [])
      video = Enum.find(videos(), &(&1.path == b.path))

      history = [watch(video.path, video.series, "entertainment", 8)]
      assert refresh(slots, "entertainment", history) == slots
      assert Offers.resting_shows(history, Rules.defaults()) == MapSet.new()

      # Each watch is judged alone, so two parts don't make a whole.
      history = history ++ [watch(video.path, video.series, "entertainment", 5)]
      assert [^a, ^b, ^c] = refresh(slots, "entertainment", history)
    end

    test "watches from before a video was offered don't replace it" do
      history = [watch("paw1", "Paw Patrol", "entertainment")]

      slots = [
        %{path: "paw1", after: 1},
        %{path: "bluey1", after: 1},
        %{path: "peppa1", after: 1}
      ]

      assert refresh(slots, "entertainment", history) == slots
    end

    test "not the show watched last, until something else has been" do
      history = [watch("paw1", "Paw Patrol", "entertainment")]
      assert MapSet.to_list(Offers.resting_shows(history, Rules.defaults())) == ["Paw Patrol"]

      fresh = refresh([], "entertainment", history)
      refute "Paw Patrol" in series(fresh)

      history = history ++ [watch("bluey1", "Bluey", "entertainment")]
      fresh = refresh([], "entertainment", history)
      assert "Paw Patrol" in series(fresh)
      refute "Bluey" in series(fresh)

      rules = %{Rules.defaults() | show_cooldown: 2}
      assert series(refresh([], "entertainment", history, rules)) |> Enum.uniq() == ["Peppa"]
    end

    test "the least watched episode of a show first" do
      rules = %{Rules.defaults() | show_cooldown: 0, offers: 2}
      history = for _ <- 1..2, do: watch("num1", "Numberblocks", "education")

      for _ <- 1..10 do
        assert "num2" in Enum.map(refresh([], "education", history, rules), & &1.path)
      end
    end

    test "gone or re-sorted videos are replaced; the offering grows and shrinks with :offers" do
      slots = [%{path: "num1", after: 0}, %{path: "gone", after: 0}, %{path: "paw1", after: 0}]
      assert [%{path: "num1"}, b, c] = refresh(slots, "education", [])
      # A show not on offer first; then either show's other episode.
      assert series([b]) == ["Alphablocks"]
      assert c.path in ["num2", "abc1", "abc2"] and c.path != b.path

      slots = refresh([], "entertainment", [])
      rules = %{Rules.defaults() | offers: 4}
      assert [_, _, _, _] = more = refresh(slots, "entertainment", [], rules)
      assert Enum.take(more, 3) == slots
      assert refresh(more, "entertainment", []) == slots
    end

    test "after 30 minutes of entertainment, education shows until 30 minutes of it" do
      rules = Rules.defaults()
      ent = fn minutes -> watch("bluey1", "Bluey", "entertainment", minutes) end
      edu = fn minutes -> watch("num1", "Numberblocks", "education", minutes) end

      # Partly watched minutes count too.
      history = [ent.(20), ent.(5)]
      assert %{only: nil, entertainment_s: 1500} = Offers.balance(history, rules)
      assert Offers.showing(history, rules) == "entertainment"

      history = history ++ [ent.(6)]
      assert %{only: "education", education_s: 0} = Offers.balance(history, rules)
      assert Offers.showing(history, rules) == "education"

      history = history ++ [edu.(20)]
      assert %{only: "education", education_s: 1200} = Offers.balance(history, rules)

      history = history ++ [edu.(10)]
      assert %{only: nil, entertainment_s: 0} = Offers.balance(history, rules)
      assert Offers.showing(history, rules) == "entertainment"

      # 0 turns it off.
      long = [ent.(300)]
      assert Offers.showing(long, rules) == "education"
      assert Offers.showing(long, %{rules | entertainment_limit_min: 0}) == "entertainment"
    end

    test "a slot nothing fits stays empty, but an offering is never emptied by the show rule" do
      rules = %{Rules.defaults() | offers: 2}
      slots = [%{path: "num1", after: 0}, %{path: "abc1", after: 0}]

      # num1 watched through: its slot can't be Numberblocks (resting) or
      # Alphablocks (on offer)... but abc2 is the only choice left, so it is.
      history = [watch("num1", "Numberblocks", "education")]
      assert [%{path: "abc2"}, %{path: "abc1"}] = refresh(slots, "education", history, rules)

      # Both watched through, only resting shows' videos left: it would be
      # empty, so they're offered after all.
      history = history ++ [watch("abc1", "Alphablocks", "education")]
      slots = [%{path: "abc2", after: 0}, %{path: "abc1", after: 0}]
      only_videos = Enum.filter(videos(), &(&1.series == "Alphablocks"))

      assert [%{path: "abc2"}] =
               Offers.refresh(slots, "education", only_videos, history, rules)

      assert Offers.refresh([], "education", [], history, rules) == []
    end
  end

  describe "History" do
    test "entries and their time played survive a restart" do
      a =
        History.start(%{
          path: "/data/a.mp4",
          title: "A",
          series: "S",
          kind: "education",
          duration_s: 600
        })

      :ok = History.watched(a.id, 30)
      :ok = History.watched(a.id, 61)
      b = History.start(%{path: "/data/b.mp4", series: "T", kind: "entertainment"})

      restart_history()

      assert [
               %{
                 id: id_a,
                 path: "/data/a.mp4",
                 title: "A",
                 kind: "education",
                 watched_s: 61,
                 duration_s: 600
               },
               %{id: id_b, path: "/data/b.mp4", watched_s: 0}
             ] = History.all()

      assert {id_a, id_b} == {a.id, b.id}
    end

    test "a cut-off last line is skipped, and the file is compacted without losing entries" do
      entry = History.start(%{path: "/data/a.mp4", series: "S", kind: "education"})
      for s <- 1..200, do: History.watched(entry.id, s)
      path = Path.join([NervesPhone.state_dir(), "kids", "history.jsonl"])
      File.write!(path, ~s({"id":"cut), [:append])

      restart_history()
      assert [%{watched_s: 200}] = History.all()
      assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 1
    end
  end

  describe "the offerings, kept" do
    setup do
      root = hd(Application.fetch_env!(:nerves_phone, :videos)[:roots])
      File.rm_rf!(root)
      File.mkdir_p!(root)

      for video <- videos() do
        path = Path.join(root, "#{video.path}.mp4")
        File.write!(path, "x")

        meta = %{
          "series" => video.series,
          "kind" => video.kind,
          "title" => video.path,
          "duration" => 600
        }

        File.write!(NervesPhone.Video.Metadata.path(path), JSON.encode!(meta))
      end

      :ok
    end

    defp play(video, minutes) do
      entry = History.start(video)
      :ok = History.watched(entry.id, minutes * 60)
    end

    test "stay until watched through; entertainment comes back as it was after education" do
      {:ok, _} = Rules.put(entertainment_limit_min: 15, education_required_min: 10)

      %{showing: "entertainment", videos: [a, b, c] = fun} = NervesPhone.Kids.offers()
      for _ <- 1..5, do: assert(NervesPhone.Kids.offers().videos == fun)

      # Stopped early: everything stays.
      play(b, 1)
      assert NervesPhone.Kids.offers().videos == fun

      # Watched through: a new one in its place.
      play(b, 10)
      assert %{videos: [^a, new, ^c]} = NervesPhone.Kids.offers()
      assert new.series != b.series

      # Past the limit: the education offering.
      play(a, 10)
      assert %{showing: "education", videos: [e1, e2, e3]} = NervesPhone.Kids.offers()
      assert Enum.all?([e1, e2, e3], &(&1.kind == "education"))

      # Enough of it: entertainment as it was, but with a's slot refilled
      # (a was watched through).
      play(e1, 10)

      assert %{showing: "entertainment", videos: [_refilled, ^new, ^c]} =
               NervesPhone.Kids.offers()

      # The next spell of education starts from where its offering was.
      play(c, 10)
      play(new, 10)
      assert %{showing: "education", videos: [e, ^e2, ^e3]} = NervesPhone.Kids.offers()
      assert e.path != e1.path
    end
  end
end
