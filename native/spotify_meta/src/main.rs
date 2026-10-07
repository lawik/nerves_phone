//! Prints a Spotify playlist's tracks as JSON on stdout.
//!
//!     spotify-meta --cache DIR playlist PLAYLIST_ID
//!
//! Signs in with the reusable credentials librespot keeps in `DIR`
//! (`credentials.json`) and reads the playlist through Spotify's own
//! metadata service. Unlike the Web API in development mode, that lists
//! any playlist you can open, not only your own. Track details are fetched
//! a few at a time, in playlist order.
//!
//! Output: `{"tracks": [{"id", "uri", "name", "artists", "album",
//! "album_uri", "duration_ms", "image_url"}], "total": N}`. Episodes and
//! local files are skipped. Errors go to stderr with a non-zero exit.

use futures_util::{stream, StreamExt};
use librespot_core::{cache::Cache, config::SessionConfig, session::Session, SpotifyUri};
use librespot_metadata::{Metadata, Playlist, Track};
use serde_json::{json, Value};
use std::process::ExitCode;

const CONCURRENT_REQUESTS: usize = 16;

#[tokio::main]
async fn main() -> ExitCode {
    match run().await {
        Ok(output) => {
            println!("{output}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("spotify-meta: {message}");
            ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<Value, String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let (cache_dir, playlist_id) = match args.as_slice() {
        [flag, dir, cmd, id] if flag == "--cache" && cmd == "playlist" => (dir, id),
        _ => return Err("usage: spotify-meta --cache DIR playlist PLAYLIST_ID".into()),
    };

    let cache = Cache::new(Some(cache_dir.as_str()), None, None, None).map_err(|e| e.to_string())?;
    let credentials = cache
        .credentials()
        .ok_or("no credentials.json in the cache directory")?;

    let session = Session::new(SessionConfig::default(), None);
    session
        .connect(credentials, false)
        .await
        .map_err(|e| format!("sign-in failed: {e}"))?;

    let uri = SpotifyUri::from_uri(&format!("spotify:playlist:{playlist_id}"))
        .map_err(|e| e.to_string())?;
    let playlist = Playlist::get(&session, &uri)
        .await
        .map_err(|e| format!("playlist: {e}"))?;

    let track_uris: Vec<SpotifyUri> = playlist
        .tracks()
        .filter(|uri| matches!(uri, SpotifyUri::Track { .. }))
        .cloned()
        .collect();

    let tracks: Vec<Value> = stream::iter(track_uris)
        .map(|uri| {
            let session = session.clone();
            async move { Track::get(&session, &uri).await.ok() }
        })
        .buffered(CONCURRENT_REQUESTS)
        .filter_map(|track| async move { track.map(|t| track_json(&t)) })
        .collect()
        .await;

    session.shutdown();
    Ok(json!({ "total": tracks.len(), "tracks": tracks }))
}

fn track_json(track: &Track) -> Value {
    let id = match &track.id {
        SpotifyUri::Track { id } => id.to_base62().unwrap_or_default(),
        _ => String::new(),
    };
    let artists: Vec<&str> = track.artists.iter().map(|a| a.name.as_str()).collect();

    // The largest cover; the image service serves it by file id.
    let image_url = track
        .album
        .covers
        .iter()
        .chain(track.album.cover_group.iter())
        .max_by_key(|image| image.width)
        .and_then(|image| image.id.to_base16().ok())
        .map(|hex| format!("https://i.scdn.co/image/{hex}"));

    json!({
        "id": id,
        "uri": track.id.to_uri().unwrap_or_default(),
        "name": track.name,
        "artists": artists.join(", "),
        "album": track.album.name,
        "album_uri": track.album.id.to_uri().ok(),
        "duration_ms": track.duration,
        "image_url": image_url,
    })
}
