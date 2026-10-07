defmodule NervesPhone.Spotify.API do
  @moduledoc """
  The parts of the Spotify Web API the player needs, returning the plain
  maps of `NervesPhone.Music.Backend`.

  Uses the endpoints as they are after Spotify's February 2026 changes for
  apps in development mode: `/playlists/{id}/items` (track lists only for
  playlists you own or collaborate on), `items` instead of `tracks`, and at
  most 10 search results per type.
  """

  alias NervesPhone.Spotify.Auth

  @base_url "https://api.spotify.com/v1"

  def me do
    with {:ok, body} <- get("/me") do
      {:ok, %{id: body["id"], name: body["display_name"] || body["id"]}}
    end
  end

  def playlists(user_id), do: playlist_pages("/me/playlists?limit=50", user_id, [])

  defp playlist_pages(nil, _user_id, acc), do: {:ok, Enum.reverse(acc)}

  defp playlist_pages(url, user_id, acc) do
    with {:ok, body} <- get(url) do
      playlists = for p <- body["items"] || [], p != nil, do: playlist(p, user_id)
      playlist_pages(body["next"], user_id, Enum.reverse(playlists, acc))
    end
  end

  def playlist_tracks(id, offset) do
    params = %{limit: 50, offset: offset, additional_types: "track"}

    case get("/playlists/#{id}/items", params) do
      {:ok, body} ->
        tracks =
          for entry <- body["items"] || [],
              item = entry["item"] || entry["track"],
              is_map(item) and item["type"] == "track" and not (entry["is_local"] == true),
              do: track(item)

        {:ok, page(body, offset, tracks)}

      # Development mode: only playlists you own or collaborate on.
      {:error, {:http, status, _}} when status in [403, 404] ->
        {:error, :not_listable}

      error ->
        error
    end
  end

  def album_tracks(id, offset) do
    with {:ok, album} <- (offset == 0 && get("/albums/#{id}")) || {:ok, nil},
         {:ok, body} <- get("/albums/#{id}/tracks", %{limit: 50, offset: offset}) do
      # Album tracks come without their album; fill it in when known.
      album_name = album && album["name"]
      image = album && image_url(album["images"])

      tracks =
        for item <- body["items"] || [] do
          item
          |> track()
          |> Map.merge(%{album: album_name || "", album_uri: "spotify:album:" <> id})
          |> Map.put(:image_url, image)
        end

      {:ok, page(body, offset, tracks)}
    end
  end

  def search(query) do
    params = %{q: query, type: "track,album,playlist", limit: 10}

    with {:ok, body} <- get("/search", params) do
      {:ok,
       %{
         tracks: for(t <- get_in(body, ["tracks", "items"]) || [], t != nil, do: track(t)),
         albums: for(a <- get_in(body, ["albums", "items"]) || [], a != nil, do: album(a)),
         playlists:
           for(p <- get_in(body, ["playlists", "items"]) || [], p != nil, do: playlist(p, nil))
       }}
    end
  end

  def device_id(name) do
    with {:ok, body} <- get("/me/player/devices") do
      {:ok, Enum.find_value(body["devices"] || [], &(&1["name"] == name && &1["id"]))}
    end
  end

  def player do
    case get("/me/player") do
      {:ok, nil} -> {:ok, nil}
      {:ok, body} -> {:ok, player_state(body)}
      error -> error
    end
  end

  def play(device_id, context_uri, offset) do
    put("/me/player/play", %{device_id: device_id}, %{
      context_uri: context_uri,
      offset: offset,
      position_ms: 0
    })
  end

  def shuffle(device_id), do: put("/me/player/shuffle", %{state: true, device_id: device_id})

  def repeat_context(device_id),
    do: put("/me/player/repeat", %{state: "context", device_id: device_id})

  def next(device_id), do: post("/me/player/next", %{device_id: device_id})
  def previous(device_id), do: post("/me/player/previous", %{device_id: device_id})
  def pause(device_id), do: put("/me/player/pause", %{device_id: device_id})

  # Play without a context resumes where it paused.
  def resume(device_id), do: put("/me/player/play", %{device_id: device_id})

  # ---------- Shapes ----------

  defp page(body, offset, items) do
    next = if body["next"], do: offset + length(body["items"] || []), else: nil
    %{items: items, next: next, total: body["total"] || 0}
  end

  defp playlist(p, user_id) do
    # `items` replaced `tracks` in 2026; accept either.
    count = p["items"] || p["tracks"] || %{}

    %{
      id: p["id"],
      uri: p["uri"],
      name: p["name"] || "",
      owner: get_in(p, ["owner", "display_name"]) || get_in(p, ["owner", "id"]) || "",
      mine: user_id != nil and get_in(p, ["owner", "id"]) == user_id,
      total: count["total"] || 0
    }
  end

  defp album(a) do
    %{
      id: a["id"],
      uri: a["uri"],
      name: a["name"] || "",
      artists: artists(a),
      year: a["release_date"] && String.slice(a["release_date"], 0, 4),
      total: a["total_tracks"] || 0
    }
  end

  defp track(t) do
    %{
      id: t["id"],
      uri: t["uri"],
      name: t["name"] || "",
      artists: artists(t),
      album: get_in(t, ["album", "name"]) || "",
      album_uri: get_in(t, ["album", "uri"]),
      duration_ms: t["duration_ms"] || 0,
      image_url: image_url(get_in(t, ["album", "images"]))
    }
  end

  defp player_state(body) do
    item = body["item"]

    %{
      device_id: get_in(body, ["device", "id"]),
      context_uri: get_in(body, ["context", "uri"]),
      is_playing: body["is_playing"] == true,
      shuffle: body["shuffle_state"] == true,
      smart_shuffle: body["smart_shuffle"] == true,
      progress_ms: body["progress_ms"] || 0,
      track: is_map(item) && item["type"] == "track" && track(item)
    }
  end

  defp artists(item), do: Enum.map_join(item["artists"] || [], ", ", & &1["name"])

  # Spotify lists images largest first.
  defp image_url([%{"url" => url} | _]), do: url
  defp image_url(_), do: nil

  # ---------- HTTP ----------

  defp get(path, params \\ %{}) do
    with {:ok, %{status: status, body: body}} <- request(:get, path, params, nil) do
      case status do
        204 -> {:ok, nil}
        s when s in 200..299 -> {:ok, body}
        s -> {:error, {:http, s, error_message(body)}}
      end
    end
  end

  defp put(path, params, body \\ nil), do: command(:put, path, params, body)
  defp post(path, params), do: command(:post, path, params, nil)

  defp command(method, path, params, body) do
    with {:ok, %{status: status, body: resp}} <- request(method, path, params, body) do
      if status in 200..299, do: :ok, else: {:error, {:http, status, error_message(resp)}}
    end
  end

  defp request(method, path, params, body) do
    with {:ok, token} <- Auth.access_token() do
      opts = [
        method: method,
        url: path,
        base_url: @base_url,
        auth: {:bearer, token},
        params: Enum.to_list(params),
        retry: :transient,
        receive_timeout: 15_000
      ]

      opts =
        cond do
          body -> Keyword.put(opts, :json, body)
          method == :get -> opts
          true -> Keyword.put(opts, :body, "")
        end

      Req.request(opts)
    end
  end

  defp error_message(%{"error" => %{"message" => message}}), do: message
  defp error_message(body), do: inspect(body)
end
