defmodule NervesPhone.DownloadsTest do
  # Uses the application's NervesPhone.Downloads, so it doesn't run async.
  use ExUnit.Case

  alias NervesPhone.Downloads

  setup do
    :ok = Downloads.subscribe()
    assert_receive {Downloads, %{count: 0, percent: nil}}
    :ok
  end

  test "counts downloads and reports the oldest's progress" do
    first = Downloads.add("https://example.com/first")
    assert_receive {Downloads, %{count: 1, percent: nil}}

    second = Downloads.add("https://example.com/second")
    assert_receive {Downloads, %{count: 2, percent: nil}}

    # Only the oldest download's progress shows.
    Downloads.progress(second, 0.5)
    Downloads.progress(first, 0.251)
    assert_receive {Downloads, %{count: 2, percent: 25}}

    # Progress within the same percent isn't sent on.
    Downloads.progress(first, 0.259)
    refute_receive {Downloads, _summary}, 50

    Downloads.remove(first)
    assert_receive {Downloads, %{count: 1, percent: 50}}

    Downloads.remove(second)
    assert_receive {Downloads, %{count: 0, percent: nil}}
  end

  test "drops the download of a process that exits" do
    test = self()

    owner =
      spawn(fn ->
        Downloads.add("https://example.com/video")
        send(test, :added)
        receive do: (:stop -> :ok)
      end)

    assert_receive :added
    assert_receive {Downloads, %{count: 1}}

    send(owner, :stop)
    assert_receive {Downloads, %{count: 0, percent: nil}}
  end
end
