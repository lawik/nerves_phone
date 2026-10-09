defmodule NervesPhone.DownloadQueueTest do
  # The queue is the app's, and waits in tests (config/host.exs).
  use ExUnit.Case, async: false

  alias NervesPhone.DownloadQueue

  setup do
    for item <- DownloadQueue.items(), do: DownloadQueue.remove(item.id)
    :ok
  end

  test "sorts links to the downloader that takes them" do
    assert {:ok, 1} = DownloadQueue.add_url("https://youtu.be/abc", "audio", "education")
    assert {:ok, 1} = DownloadQueue.add_url(" https://www.svtplay.se/video/x ", "video")
    assert {:ok, 1} = DownloadQueue.add_url("https://urplay.se/serie/y", "all_episodes")
    assert {:ok, 1} = DownloadQueue.add_url("https://vimeo.com/1", "video")

    assert [
             %{source: :youtube, mode: :audio, label: "YouTube", kind: "education"},
             %{
               source: :svt,
               mode: :one,
               label: "SVT Play",
               url: "https://www.svtplay.se/video/x"
             },
             %{source: :svt, mode: :all_episodes, label: "UR Play"},
             %{source: :youtube, mode: :video, label: "vimeo.com", status: :queued}
           ] = DownloadQueue.items()

    assert {:error, "Paste a web address" <> _} = DownloadQueue.add_url("not a link", "video")

    assert {:error, "All episodes is for" <> _} =
             DownloadQueue.add_url("https://youtu.be/abc", "all_episodes")

    assert {:error, "There's no kind" <> _} =
             DownloadQueue.add_url("https://youtu.be/abc", "video", "chores")
  end

  test "is kept across restarts, and tells subscribers" do
    :ok = DownloadQueue.subscribe()
    assert_receive {DownloadQueue, []}

    result = %{source: :youtube, title: "Tandborsten", url: "https://youtu.be/gfqTkhzrjPo"}
    :ok = DownloadQueue.add(result, :video, "entertainment")
    assert_receive {DownloadQueue, [%{title: "Tandborsten", status: :queued}]}

    :ok = Supervisor.terminate_child(NervesPhone.Supervisor, DownloadQueue)
    {:ok, _} = Supervisor.restart_child(NervesPhone.Supervisor, DownloadQueue)

    assert [%{title: "Tandborsten", kind: "entertainment", source: :youtube, mode: :video}] =
             DownloadQueue.items()
  end

  test "removes, and clears what's finished" do
    {:ok, 1} = DownloadQueue.add_url("https://youtu.be/a", "video")
    {:ok, 1} = DownloadQueue.add_url("https://youtu.be/b", "video")
    [a, b] = DownloadQueue.items()

    :ok = DownloadQueue.remove(a.id)
    assert [%{id: id}] = DownloadQueue.items()
    assert id == b.id

    :ok = DownloadQueue.clear_finished()
    assert [_queued] = DownloadQueue.items()
  end
end
