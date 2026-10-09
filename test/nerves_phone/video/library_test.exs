defmodule NervesPhone.Video.LibraryTest do
  # The library's folders are app config.
  use ExUnit.Case, async: false

  alias NervesPhone.Video.Library

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    config = Application.get_env(:nerves_phone, :videos)
    Application.put_env(:nerves_phone, :videos, roots: [dir])
    on_exit(fn -> Application.put_env(:nerves_phone, :videos, config) end)
  end

  test "deletes a video with what's kept beside it, and only library videos", %{tmp_dir: dir} do
    video = Path.join(dir, "show/ep1.mp4")
    File.mkdir_p!(Path.dirname(video))
    File.write!(video, String.duplicate("v", 100))
    File.write!(Path.join(dir, "show/ep1.jpg"), String.duplicate("j", 10))
    File.write!(Path.join(dir, "show/ep1.meta.json"), "{}")
    File.write!(Path.join(dir, "show/ep2.mp4"), "")
    File.write!(Path.join(dir, "notes.txt"), "")

    assert [%{total_size: 112, size: 100}] = Enum.filter(Library.videos(), &(&1.path == video))

    assert {:error, _} = Library.delete(Path.join(dir, "notes.txt"))
    assert {:error, _} = Library.delete("/etc/hosts")

    assert {:ok, 112} = Library.delete(video)
    assert File.ls!(Path.join(dir, "show")) == ["ep2.mp4"]
    assert File.exists?(Path.join(dir, "notes.txt"))
  end

  test "says how full the disk is", %{tmp_dir: _dir} do
    assert [%{total: total, used: used, available: available, mount: "/" <> _}] = Library.disk()
    assert total > 0 and used > 0 and available > 0
  end
end
