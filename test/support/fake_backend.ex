defmodule NervesPhone.Music.FakeBackend do
  @moduledoc false
  # A music service for tests. Records commands in an Agent so tests can
  # check what was sent, and lets them change the playback it reports.

  @behaviour NervesPhone.Music.Backend

  def start_link do
    Agent.start_link(
      fn -> %{calls: [], shuffle: true, smart_shuffle: false, playing: true} end,
      name: __MODULE__
    )
  end

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def set(fields), do: Agent.update(__MODULE__, &Map.merge(&1, Map.new(fields)))
  defp record(call), do: Agent.update(__MODULE__, &%{&1 | calls: [call | &1.calls]})

  @impl true
  def name, do: "fake"

  @impl true
  def children, do: []

  @impl true
  def audio_fifo, do: "/dev/null"

  @impl true
  def setup_hint, do: nil

  @impl true
  def playlists do
    named = [
      playlist("p1", "Morning Coffee", "Me", true, 48),
      playlist("p2", "Deep Focus", "Me", true, 212),
      playlist("p3", "Road Trip 2026", "Sam", false, 97),
      playlist("p4", "Friday Night", "Me", true, 63),
      playlist("p5", "Jazz Classics", "Alex", false, 150)
    ]

    {:ok, named ++ for(i <- 6..40, do: playlist("p#{i}", "Mix #{i}", "Me", rem(i, 3) != 0, i))}
  end

  defp playlist(id, name, owner, mine, total),
    do: %{id: id, uri: "fake:playlist:" <> id, name: name, owner: owner, mine: mine, total: total}

  # p3 isn't listable, like someone else's playlist in Spotify's dev mode.
  @impl true
  def tracks(:playlist, "p3", _offset), do: {:error, :not_listable}

  def tracks(kind, id, offset) do
    total = if id == "p2", do: 120, else: 12
    count = min(50, total - offset)

    items =
      for i <- (offset + 1)..(offset + count)//1 do
        track("#{kind}-#{id}-#{i}", "Song #{i} of #{id}", "Artist #{rem(i, 4) + 1}")
      end

    next = if offset + count < total, do: offset + count
    {:ok, %{items: items, next: next, total: total}}
  end

  @impl true
  def search(query) do
    {:ok,
     %{
       tracks: [track("s1", "#{query} (Radio Edit)", "The Searchers")],
       albums: [
         %{
           id: "a1",
           uri: "fake:album:a1",
           name: "Best of #{query}",
           artists: "The Searchers",
           year: "1999",
           total: 12
         }
       ],
       playlists: [playlist("sp1", "#{query} Classics", "Someone", false, 30)]
     }}
  end

  defp track(id, name, artists) do
    %{
      id: id,
      uri: "fake:track:" <> id,
      name: name,
      artists: artists,
      album: "Some Album",
      album_uri: "fake:album:x",
      duration_ms: 241_000,
      image_url: nil
    }
  end

  @impl true
  def playback do
    state = Agent.get(__MODULE__, & &1)

    {:ok,
     %{
       device_ready: true,
       playback: %{
         context_uri: "fake:playlist:p2",
         track: %{
           track("t1", "Weightless Afternoon", "The Quiet Rooms, Lumen")
           | uri: "fake:track:playlist-p2-3"
         },
         is_playing: state.playing,
         progress_ms: 83_000,
         shuffle: state.shuffle,
         smart_shuffle: state.smart_shuffle
       }
     }}
  end

  @impl true
  def play(context_uri, start), do: record({:play, context_uri, start})

  @impl true
  def ensure_shuffle, do: record(:ensure_shuffle)

  @impl true
  def pause, do: record(:pause)

  @impl true
  def resume, do: record(:resume)

  @impl true
  def next, do: record(:next)

  @impl true
  def previous, do: record(:previous)
end
