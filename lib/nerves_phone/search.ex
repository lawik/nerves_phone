defmodule NervesPhone.Search do
  @moduledoc """
  Searches YouTube (with `NervesPhone.YtDlp`) and SVT Play (with
  `NervesPhone.SvtPlay.Catalog`), with results in one shape, which
  `NervesPhone.DownloadQueue.add/3` takes. phone_remote searches with it.

  Only what can be downloaded now is kept: on YouTube that leaves out
  live streams (which never finish downloading) and premieres that
  haven't started; see `NervesPhone.SvtPlay.Catalog` for SVT Play.
  """

  alias NervesPhone.SvtPlay.Catalog
  alias NervesPhone.YtDlp

  @typedoc """
  `source` is the downloader: `:youtube` is yt-dlp, `:svt` svtplay-dl.
  `series?` is an SVT programme with episodes (see
  `NervesPhone.SvtPlay.Catalog.episodes/1`).
  """
  @type result :: %{
          source: :youtube | :svt,
          id: String.t(),
          title: String.t(),
          subtitle: String.t() | nil,
          url: String.t(),
          thumbnail: String.t() | nil,
          duration: String.t() | nil,
          series?: boolean()
        }

  @spec search(:youtube | :svt, String.t()) :: {:ok, [result()]} | {:error, String.t()}
  def search(:svt, query), do: Catalog.search(query)

  def search(:youtube, query) do
    with {:ok, entries} <- YtDlp.search(query, limit: 15) do
      {:ok, entries |> Enum.filter(&downloadable?/1) |> Enum.map(&youtube_result/1)}
    end
  end

  # live_status is nil when yt-dlp can't tell.
  defp downloadable?(entry),
    do: not entry.is_live and entry.live_status not in ["is_upcoming", "is_live"]

  defp youtube_result(entry) do
    %{
      source: :youtube,
      id: entry.id,
      title: entry.title || entry.id,
      subtitle: entry.channel,
      url: entry.url || "https://www.youtube.com/watch?v=#{entry.id}",
      thumbnail: entry.thumbnail,
      duration: duration(entry.duration),
      series?: false
    }
  end

  defp duration(nil), do: nil

  defp duration(seconds) do
    seconds = trunc(seconds)
    {h, m, s} = {div(seconds, 3600), div(rem(seconds, 3600), 60), rem(seconds, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end
end
