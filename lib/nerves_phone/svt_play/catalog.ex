defmodule NervesPhone.SvtPlay.Catalog do
  @moduledoc """
  Searches SVT Play and lists programmes' episodes, through the GraphQL
  API its website uses (`api.svt.se/contento/graphql`), for
  `NervesPhone.Search` and `NervesPhone.DownloadQueue`. It answers plain
  queries, not only the website's persisted ones, so this asks for just
  the fields it shows.

  Only what can be downloaded now is listed: things published and not
  yet expired (`validFrom` to `validTo`), and not copy-protected, as
  svtplay-dl can't decrypt DRM. Programmes with episodes (`series?:
  true`) are listed as long as SVT has them; their episodes are filtered
  the same way by `episodes/1`.
  """

  @endpoint "https://api.svt.se/contento/graphql"

  # The availability of things that are played rather than hold episodes.
  @availability """
  ... on Episode { validFrom validTo restrictions { drmCopyProtection } }
  ... on Single { validFrom validTo restrictions { drmCopyProtection } }
  ... on Clip { validFrom validTo }
  """

  @teaser """
  teaser {
    heading
    subHeading
    description
    durationFormatted
    item { __typename urls { svtplay } #{@availability} }
    image { id changed }
  }
  """

  @search """
  query Search($query: String!) {
    searchPage(query: $query) {
      flat { hits { #{@teaser} } }
      sectioned { hits { #{@teaser} } }
    }
  }
  """

  @episodes """
  query Episodes($path: String!) {
    detailsPageByPath(path: $path) {
      heading
      associatedContent {
        id
        name
        selectionType
        items {
          heading
          subHeading
          image { id changed }
          item {
            __typename
            urls { svtplay }
            ... on Episode { positionInSeason durationFormatted }
            #{@availability}
          }
        }
      }
    }
  }
  """

  # Item types that hold episodes rather than being one.
  @series ~w(TvShow TvSeries KidsTvShow)

  # Selections with episodes (seasons, a daily show's broadcasts, clips),
  # as opposed to upcoming live broadcasts and other programmes.
  @episode_selections ~w(season productionPeriod clips)

  @typedoc "A group of episodes, such as a season."
  @type section :: %{id: String.t(), name: String.t(), episodes: [NervesPhone.Search.result()]}

  @spec search(String.t()) :: {:ok, [NervesPhone.Search.result()]} | {:error, String.t()}
  def search(query) do
    with {:ok, %{"searchPage" => page}} <- request(@search, %{query: query}) do
      # Usually the hits are flat, but some searches only come in sections.
      hits =
        get_in(page, ["flat", "hits"]) ||
          Enum.flat_map(page["sectioned"] || [], &(&1["hits"] || []))

      # Category hits have no teaser, and some teasers aren't programmes.
      results =
        for %{"teaser" => teaser} when teaser != nil <- hits,
            available?(teaser["item"]),
            result = to_result(teaser),
            result != nil,
            do: result

      {:ok, Enum.uniq_by(results, & &1.url)}
    end
  end

  @doc """
  The downloadable episodes of the programme at `url`, by season (or
  however SVT groups them), in SVT's order. Empty sections are left out.
  """
  @spec episodes(String.t()) :: {:ok, [section()]} | {:error, String.t()}
  def episodes(url) do
    path = URI.parse(url).path

    case request(@episodes, %{path: path}) do
      {:ok, %{"detailsPageByPath" => %{"heading" => programme} = page}} ->
        sections =
          for %{"selectionType" => type} = selection <- page["associatedContent"] || [],
              type in @episode_selections,
              episodes = episodes_of(selection, programme),
              episodes != [],
              do: %{id: selection["id"], name: selection["name"], episodes: episodes}

        {:ok, sections}

      {:ok, _no_page} ->
        {:error, "SVT Play has no programme at #{path}"}

      error ->
        error
    end
  end

  defp episodes_of(selection, programme) do
    for teaser <- selection["items"] || [],
        available?(teaser["item"]),
        %{"urls" => %{"svtplay" => path}} = item = teaser["item"],
        is_binary(path) do
      %{
        source: :svt,
        id: path,
        # The episode's own name, and with the programme's for the queue.
        name: strip(teaser["heading"]),
        title: "#{programme} – #{strip(teaser["heading"])}",
        subtitle:
          Enum.find(
            [item["positionInSeason"], strip(teaser["subHeading"])],
            &(&1 not in [nil, ""])
          ),
        url: "https://www.svtplay.se" <> path,
        thumbnail: image_url(teaser["image"]),
        duration: item["durationFormatted"],
        series?: false
      }
    end
  end

  @doc """
  Whether an item can be downloaded now: published, not expired, and not
  copy-protected. Programmes with episodes have no dates of their own.
  """
  @spec available?(map() | nil, DateTime.t()) :: boolean()
  def available?(item, now \\ DateTime.utc_now())

  def available?(nil, _now), do: false

  def available?(item, now) do
    get_in(item, ["restrictions", "drmCopyProtection"]) != true and
      not after?(item["validFrom"], now) and
      not before?(item["validTo"], now)
  end

  # Whether a timestamp is later or earlier than now; a missing one isn't
  # either.
  defp after?(timestamp, now), do: compare(timestamp, now) == :gt
  defp before?(timestamp, now), do: compare(timestamp, now) == :lt

  defp compare(nil, _now), do: :eq

  defp compare(timestamp, now) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, time, _offset} -> DateTime.compare(time, now)
      {:error, _reason} -> :eq
    end
  end

  defp request(query, variables) do
    case Req.post(@endpoint,
           params: [ua: "svtplaywebb-play-render-prod-client"],
           json: %{query: query, variables: variables},
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_map(data) ->
        {:ok, data}

      {:ok, %{body: %{"errors" => [%{"message" => message} | _]}}} ->
        {:error, "SVT Play said: #{message}"}

      {:ok, %{status: status}} ->
        {:error, "SVT Play answered #{status}"}

      {:error, exception} ->
        {:error, "Couldn't reach SVT Play: #{Exception.message(exception)}"}
    end
  end

  defp to_result(%{"item" => %{"urls" => %{"svtplay" => path}} = item} = teaser)
       when is_binary(path) do
    %{
      source: :svt,
      id: path,
      title: strip(teaser["heading"]),
      subtitle:
        Enum.find([strip(teaser["subHeading"]), strip(teaser["description"])], &(&1 != "")),
      url: "https://www.svtplay.se" <> path,
      thumbnail: image_url(teaser["image"]),
      duration: teaser["durationFormatted"],
      series?: item["__typename"] in @series
    }
  end

  defp to_result(_teaser), do: nil

  # How svtplay.se builds its image URLs.
  defp image_url(%{"id" => id, "changed" => changed}),
    do: "https://www.svtstatic.se/image/custom/400/#{id}/#{changed}?format=auto"

  defp image_url(_image), do: nil

  # Headings mark the matched words with <em>.
  defp strip(nil), do: ""
  defp strip(text), do: text |> String.replace(~r/<[^>]*>/, "") |> String.trim()
end
