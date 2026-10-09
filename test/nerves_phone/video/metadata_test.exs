defmodule NervesPhone.Video.MetadataTest do
  use ExUnit.Case, async: true

  alias NervesPhone.Video.Metadata

  @moduletag :tmp_dir

  test "writes what yt-dlp knows next to the video, and reads it back", %{tmp_dir: dir} do
    video = Path.join(dir, "Tandborsten [gfqTkhzrjPo].mp4")
    File.write!(video, "")
    File.write!(Path.join(dir, "Tandborsten [gfqTkhzrjPo].jpg"), "")

    info = %{
      "id" => "gfqTkhzrjPo",
      "title" => "Tandborsten i Yrias värld",
      "description" => "Två gånger om dagen",
      "duration" => 141,
      "channel" => "Yrias värld",
      "upload_date" => "20250923",
      "categories" => ["Music"],
      "tags" => [],
      "age_limit" => 0,
      "extractor_key" => "Youtube",
      "webpage_url" => "https://www.youtube.com/watch?v=gfqTkhzrjPo"
    }

    assert :ok = Metadata.write(video, Metadata.from_yt_dlp(info))
    assert {:ok, meta} = Metadata.read(video)

    assert %{
             "title" => "Tandborsten i Yrias värld",
             "duration" => 141,
             "series" => "Yrias värld",
             "published" => "2025-09-23",
             "categories" => ["Music"],
             "source" => "youtube",
             "file" => "Tandborsten [gfqTkhzrjPo].mp4",
             "thumbnail" => "Tandborsten [gfqTkhzrjPo].jpg",
             "raw" => %{"id" => "gfqTkhzrjPo"}
           } = meta
  end

  test "takes the programme, genres and tags from SVT Play", %{tmp_dir: dir} do
    video = Path.join(dir, "leka-med-tag.mp4")
    File.write!(video, "")

    page = %{
      "heading" => "Leka med tåg",
      "description" => "Del 5 av 5.",
      "item" => %{
        "svtId" => "KLJDn6z",
        "name" => "Leka med tåg",
        "longDescription" => "",
        "duration" => 327,
        "validFrom" => "2026-09-10T02:00:00+02:00",
        "number" => 5,
        "genres" => [%{"name" => "Barn"}],
        "tags" => [%{"name" => "Underhållning"}, %{"name" => "alder-3-5"}],
        "parent" => %{"name" => "Bolibompaförskolan", "genres" => [%{"name" => "Barn"}]}
      }
    }

    Metadata.write(video, Metadata.from_svt(page, "https://www.svtplay.se/video/KLJDn6z"))
    {:ok, meta} = Metadata.read(video)

    assert %{
             "title" => "Leka med tåg",
             # An empty long description falls back to the page's.
             "description" => "Del 5 av 5.",
             "series" => "Bolibompaförskolan",
             "episode" => 5,
             "published" => "2026-09-10",
             "categories" => ["Barn"],
             "tags" => ["Underhållning", "alder-3-5"],
             "thumbnail" => nil
           } = meta
  end

  test "without a site's metadata, it's named after the file", %{tmp_dir: dir} do
    video = Path.join(dir, "programme.s01e01.mp4")
    File.write!(video, "")

    Metadata.write(video, %{"url" => "https://urplay.se/program/1", "source" => "urplay"})

    assert {:ok, %{"title" => "programme.s01e01", "source" => "urplay", "duration" => nil}} =
             Metadata.read(video)
  end

  test "sorts a video, keeping what's known about it", %{tmp_dir: dir} do
    video = Path.join(dir, "tag.mp4")
    File.write!(video, "")

    :ok = Metadata.write(video, %{"title" => "Leka med tåg", "kind" => "entertainment"})
    assert {:ok, %{"kind" => "entertainment"}} = Metadata.read(video)

    assert :ok = Metadata.put_kind(video, "education")
    assert {:ok, %{"kind" => "education", "title" => "Leka med tåg"}} = Metadata.read(video)

    assert :ok = Metadata.put_kind(video, nil)
    assert {:ok, %{"kind" => nil}} = Metadata.read(video)
  end

  test "sorts a video that has no metadata yet", %{tmp_dir: dir} do
    video = Path.join(dir, "old.mp4")
    File.write!(video, "")

    assert :ok = Metadata.put_kind(video, "entertainment")
    assert {:ok, %{"kind" => "entertainment", "title" => "old"}} = Metadata.read(video)
  end
end
