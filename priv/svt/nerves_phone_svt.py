"""SVT Play's own description of a programme, for NervesPhone.SvtPlay to
keep with what it downloads.

svtplay-dl only writes a Kodi NFO (no duration or genres), so this asks
the GraphQL API svtplay.se uses, by the programme's path, and fetches its
image. Uses requests and certifi, which come with svtplay-dl.
"""

from urllib.parse import urlparse

import requests

_ENDPOINT = "https://api.svt.se/contento/graphql"
_PARAMS = {"ua": "svtplaywebb-play-render-prod-client"}

# Everything that can be played: an episode of a programme, a single
# (a film, say), a clip or a trailer.
_QUERY = """
query Details($path: String!) {
  detailsPageByPath(path: $path) {
    heading
    description
    item {
      __typename
      ... on Episode {
        id svtId name longDescription duration validFrom productionYear
        positionInSeason number
        tags { name } genres { name } image { id changed }
        parent {
          __typename
          ... on TvShow { name genres { name } }
          ... on TvSeries { name genres { name } }
          ... on KidsTvShow { name genres { name } }
        }
      }
      ... on Single {
        id svtId name longDescription duration validFrom productionYear
        tags { name } genres { name } image { id changed }
      }
      ... on Trailer {
        id svtId name longDescription duration validFrom
        tags { name } image { id changed }
      }
      ... on Clip {
        id svtId name longDescription duration validFrom
        tags { name } image { id changed }
      }
    }
  }
}
"""


def details(url):
    """The details page for a programme's URL, or None if SVT has none."""
    response = requests.post(
        _ENDPOINT,
        params=_PARAMS,
        json={"query": _QUERY, "variables": {"path": urlparse(url).path}},
        timeout=20,
    )
    response.raise_for_status()
    return (response.json().get("data") or {}).get("detailsPageByPath")


def image_url(image, width=800):
    """How svtplay.se builds its image URLs."""
    if not image or not image.get("id"):
        return None
    return f"https://www.svtstatic.se/image/custom/{width}/{image['id']}/{image.get('changed', '')}"


def fetch(url, path):
    """Saves the image at url to path, as JPEG (the image service picks
    the format from Accept)."""
    response = requests.get(url, headers={"Accept": "image/jpeg"}, timeout=20)
    response.raise_for_status()
    with open(path, "wb") as file:
        file.write(response.content)
