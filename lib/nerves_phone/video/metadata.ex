defmodule NervesPhone.Video.Metadata do
  @moduledoc """
  What's known about a downloaded video, kept next to it as
  `<name>.meta.json`, with its thumbnail as `<name>.jpg`.

  `NervesPhone.YtDlp` and `NervesPhone.SvtPlay` write it when a download
  finishes, in the same shape whichever site it came from:

    * `"title"`, `"description"`, `"duration"` (seconds)
    * `"series"` (an SVT programme, or a YouTube channel), `"season"`,
      `"episode"`, `"creator"` (who made it)
    * `"published"` (`"2026-09-10"`), `"language"`, `"age_limit"`
    * `"categories"` (YouTube's, such as "Education", or SVT's genres,
      such as "Barn") and `"tags"` (SVT's say more, such as
      "Underhållning" or "alder-3-5"), for sorting videos later, such as
      into entertainment and education
    * `"source"` (`"youtube"`, `"svtplay"`, ...), `"url"`, `"id"`
    * `"file"` and `"thumbnail"` (file names in the same folder; the
      thumbnail is nil when there's none), `"downloaded_at"`
    * `"kind"`: how it's been sorted, `"education"` or
      `"entertainment"`, or nil while it isn't. It's set when the download
      is queued (the downloads' `:kind` option) or later, with `put_kind/2`
    * `"raw"`: everything the site said, for whatever's needed later
      (less the lists of stream URLs, which expire anyway)

  Values the site doesn't give are nil (or empty lists). When it gives no
  duration, it's read from the file with ffprobe.
  """

  require Logger

  @version 1

  @kinds ~w(education entertainment)

  @typedoc "How a video is sorted; nil while it isn't."
  @type kind :: String.t() | nil

  @doc "The kinds videos are sorted into."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Where a video's metadata goes."
  @spec path(Path.t()) :: Path.t()
  def path(video), do: Path.rootname(video) <> ".meta.json"

  @doc "Where a video's thumbnail goes."
  @spec thumbnail_path(Path.t()) :: Path.t()
  def thumbnail_path(video), do: Path.rootname(video) <> ".jpg"

  @doc "A video's metadata, if it has any."
  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(video) do
    with {:ok, json} <- File.read(path(video)), do: JSON.decode(json)
  end

  @doc """
  Writes a video's metadata from what's known (see the moduledoc for the
  keys), filling in what's missing. Failing to write is logged, as the
  video itself is fine.
  """
  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(video, known) do
    thumbnail = thumbnail_path(video)

    meta =
      %{
        "version" => @version,
        "file" => Path.basename(video),
        "title" => Path.rootname(Path.basename(video)),
        "description" => nil,
        "duration" => nil,
        "series" => nil,
        "season" => nil,
        "episode" => nil,
        "creator" => nil,
        "published" => nil,
        "language" => nil,
        "age_limit" => nil,
        "categories" => [],
        "tags" => [],
        "source" => nil,
        "url" => nil,
        "id" => nil,
        "kind" => nil,
        "raw" => %{}
      }
      |> Map.merge(reject_nil(known))
      |> Map.put("thumbnail", if(File.exists?(thumbnail), do: Path.basename(thumbnail)))
      |> Map.put("downloaded_at", DateTime.utc_now() |> DateTime.truncate(:second))
      |> Map.update!("duration", &(&1 || probe_duration(video)))

    save(video, meta)
  end

  @doc """
  Sorts a video, or unsorts it with nil. A video without metadata (from
  before it was kept) gets what `write/2` can find out.
  """
  @spec put_kind(Path.t(), kind()) :: :ok | {:error, term()}
  def put_kind(video, kind) when kind in @kinds or is_nil(kind) do
    case read(video) do
      {:ok, meta} -> save(video, Map.put(meta, "kind", kind))
      {:error, _none} -> write(video, %{"kind" => kind})
    end
  end

  defp save(video, meta) do
    case File.write(path(video), JSON.encode!(meta)) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Couldn't write #{path(video)}: #{:file.format_error(reason)}")
        error
    end
  end

  @doc "The known keys from yt-dlp's info for a download."
  @spec from_yt_dlp(map()) :: map()
  def from_yt_dlp(info) do
    %{
      "title" => info["title"],
      "description" => info["description"],
      "duration" => info["duration"],
      "series" => info["series"] || info["channel"],
      "season" => info["season_number"],
      "episode" => info["episode_number"],
      "creator" => info["channel"] || info["uploader"],
      "published" => date(info["upload_date"] || info["release_date"]),
      "language" => info["language"],
      "age_limit" => info["age_limit"],
      "categories" => info["categories"] || [],
      "tags" => info["tags"] || [],
      "source" => info["extractor_key"] && String.downcase(info["extractor_key"]),
      "url" => info["webpage_url"],
      "id" => info["id"],
      "raw" => info
    }
  end

  @doc "The known keys from SVT Play's details page for a programme."
  @spec from_svt(map(), String.t()) :: map()
  def from_svt(%{"item" => item} = page, url) do
    parent = item["parent"] || %{}
    genres = names(item["genres"]) ++ names(parent["genres"])

    %{
      "title" => item["name"] || page["heading"],
      "description" => nonempty(item["longDescription"]) || page["description"],
      "duration" => item["duration"],
      "series" => parent["name"],
      "episode" => item["number"],
      "creator" => "SVT",
      "published" => item["validFrom"] && String.slice(item["validFrom"], 0, 10),
      "categories" => Enum.uniq(genres),
      "tags" => names(item["tags"]),
      "source" => "svtplay",
      "url" => url,
      "id" => item["svtId"] || item["id"],
      "raw" => page
    }
  end

  defp names(nil), do: []
  defp names(list), do: for(%{"name" => name} <- list, do: name)

  # yt-dlp's dates are "20260910".
  defp date(<<y::binary-4, m::binary-2, d::binary-2>>), do: "#{y}-#{m}-#{d}"
  defp date(_other), do: nil

  defp nonempty(""), do: nil
  defp nonempty(value), do: value

  defp reject_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp probe_duration(video) do
    args = ~w(-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1)

    with ffprobe when is_binary(ffprobe) <- System.find_executable("ffprobe"),
         {out, 0} <- System.cmd(ffprobe, args ++ [video], stderr_to_stdout: true),
         {seconds, _rest} <- Float.parse(String.trim(out)) do
      round(seconds)
    else
      _no_duration -> nil
    end
  end
end
