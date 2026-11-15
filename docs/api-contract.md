# MoviePilot API contract

This document describes the MoviePilot API conventions used by the 1.3 feature branch. Discovery, identity lookup, season selection and resource endpoints were checked against backend source and authenticated read-only responses on 2026-11-15. Live subscription creation and resource download submission were not exercised. Build, fixture and physical-device results are recorded separately. [1.1.0](https://github.com/dakotazhang/Devilking-MP/releases/tag/v1.1.0) is a previously published version.

Use authenticated read-only requests when checking a new deployment. Do not trigger downloads, site refreshes or scheduler jobs as connection tests.

## Authentication and response envelope

- Username/password: `POST /api/v1/login/access-token` with form-encoded `username` and `password`. Use the returned JWT in `Authorization: Bearer ...`.
- API token/key: use the `X-API-KEY` header. A raw API token is not a JWT and must not be passed as Bearer.
- Keep credentials out of URL query parameters, logs, screenshots, fixtures and issue reports.
- MoviePilot 3 responses commonly use `{ "success": true, "message": "", "data": ... }`, including collection endpoints. Check `success` before consuming `data`.
- The client also accepts supported legacy bare-array responses. An HTML login page or an unexpected object is not an empty successful collection.
- OpenAPI documentation may be disabled by `API_DOCS_ENABLE`, producing404. Do not enable documentation or weaken authentication merely to make a connection test pass.

## Endpoint reference

| Purpose | Request | Response data |
| --- | --- | --- |
| Authenticated service check | GET `/api/v1/system/ping` | Success envelope with null data |
| Subscription list | GET `/api/v1/subscribe/` | Subscription objects |
| Subscription detail | GET `/api/v1/subscribe/{id}` | A permission-scoped subscription |
| Cached account statistics | GET `/api/v1/site/userdata/latest` | Latest cached SiteUserData records |
| Site configuration | GET `/api/v1/site/` | Configuration containing sensitive fields; not account totals |
| Metadata title search | GET `/api/v1/media/search?title=...&type=media&page=1&count=20` | Media metadata |
| User recommendation selection | GET `/api/v1/user/config/Recommend` | Current enabled recommendation section names |
| Recommendation and media providers | GET `/api/v1/recommend/source`, `/api/v1/media/source` | Extension section declarations and available media sources |
| Configured built-in recommendation sections | GET supported `/api/v1/recommend/...` and `/api/v1/anilist/...` routes | Media lists, bounded `page` and `count` |
| MoviePilot poster image | GET `/api/v1/system/cache/image?url=...` | Authenticated image response for a validated public artwork reference |
| Native media detail | GET `/api/v1/media/{media_id}?media_source=...&type_name=...` | One media object |
| TV season selection | GET `/api/v1/media/seasons?media_source=...&media_id=...&type_name=电视剧` | Season objects including `season_number` |
| Existing subscription | GET `/api/v1/subscribe/media/{media_id}?media_source=...` | Subscription or an empty subscription object with null `id` |
| Create one subscription | POST `/api/v1/subscribe/` | Success envelope with `data.id`; a live server may return an existing identity |
| Connected search sites | GET `/api/v1/site/?page=1&count=200` | Enabled site identities; discard credentials and restricted links |
| Enabled downloaders | GET `/api/v1/download/clients` | Downloader names and types |
| Downloader identity for explicit mapping | GET `/api/v1/system/settings/describe/Downloaders?include_value=true&show_secrets=false` | Enabled downloader configuration; retain only name, type and sanitized endpoint identity |
| Preset download directories | GET `/api/v1/download/paths` | Names, save paths and storage types |
| Explicit tracker title search | GET `/api/v1/search/title?keyword=...&sites=...&page=0` | Resource contexts containing `media_info` and `torrent_info` |
| Selected-media tracker search | GET `/api/v1/search/media/{media_id}?media_source=...&mtype=...&area=title&sites=...` | Resource contexts; add the explicitly selected TV `season` |
| Submit one resource download | POST `/api/v1/download/` | Success envelope with `data.download_id`; acceptance is not completion |

`/api/v1/search/title` searches tracker resources; it is not the metadata search endpoint. POST `/api/v1/site/userdata/{id}` requests a site refresh and must not be used for routine dashboard polling. Reading cached account data does not itself require a new tracker or site login.

Where supported, `page`/`count` and `X-Total-Count` describe pagination. Bound page sizes and distinguish a loaded page from the full server total.

## Subscription fields and states

| Purpose | Fields |
| --- | --- |
| Subscription identity | `id` |
| Display | `name`, `year`, `type`, optional `season` |
| Artwork and description | `poster`, `description` |
| Episode progress | `total_episode`, `lack_episode`, optional `completed_episode` |
| Music progress | Optional `total_tracks`, `completed_tracks` |
| Metadata identity | `media_source` together with `media_id` |
| Execution status | Optional `execution_status` object |

Clamp derived progress. Missing totals must not imply completion. Keep execution state separate from the persistent subscription state: `execution_status` may describe queued/running work even when the subscription has been suspended.

| State | Meaning |
| --- | --- |
| N | New / 新建 |
| R | Resolved / 订阅中 |
| P | Pending / 待定; searches may continue, completion is deferred |
| S | Suspended / 暂停 automatic scheduling |

Pause with `PUT /api/v1/subscribe/status/{id}?state=S`; resume with `state=R`. There is no request body. The route accepts R/P/S and returns a success envelope. HTTP200 alone does not confirm a successful mutation.

**Suspending is not cancellation.** An already accepted search or explicitly targeted manual search may continue. The app's initial management surface does not expose search-job cancellation, forced search or subscription deletion. Require explicit confirmation and current authorization before a single status change; never automatically replay a write whose outcome is uncertain.

## Cached account data

| App value | SiteUserData field | Interpretation |
| --- | --- | --- |
| Display name | `name` | Site display name |
| Domain identity | `domain` | Avoid exposing credential-bearing paths |
| Uploaded bytes | `upload` | Integer bytes |
| Downloaded bytes | `download` | Integer bytes |
| Ratio | `ratio` | Optional number; unknown is distinct from zero |
| Seeding count | `seeding` | Integer |
| Leeching count | `leeching` | Integer |
| Seeding size | `seeding_size` | Integer bytes |
| Collection error | `err_msg` | Nonempty means collection trouble; do not echo sensitive raw details |
| Cache timestamp | `updated_day`, `updated_time` | Separate from the app's request timestamp |

Missing fields remain unknown. Empty `err_msg` alone is insufficient evidence of complete, current data. Cached records can be stale or contain collection errors while MoviePilot itself remains online.

`is_active` belongs to site configuration, not SiteUserData. Do not infer enabled/disabled state from traffic, account errors or absent statistics. If configuration is needed for an explicit feature, immediately discard unneeded `cookie`, `rss`, `apikey`, `token` and related sensitive fields. Never persist or log the whole configuration response. `/site/statistic` describes request success/failure statistics, not upload/download totals.

## Metadata search

- Use `media_source` and `media_id` together as the native identity. Source-specific IDs such as `tmdb_id` and `douban_id` are optional compatibility fields.
- Display `title`, `year`, `type`, `overview` and optional `vote_average`.
- `poster_path` and `backdrop_path` can be absent. Do not append service credentials to public artwork URLs.
- Fixtures must use synthetic identities and titles. Never copy a user's media history, site identity or restricted URLs into public tests.

## Discovery and subscription creation

The application follows the current MoviePilot user's recommendation selection and available media providers. It supports fifteen built-in sections across TMDB, Douban, Bangumi and AniList, retaining their catalog order and bounding each list to twelve items. Supported extension declarations may select a known route; an unknown extension is shown with a link-back explanation and is never executed as arbitrary plugin code. A failed section keeps an explicit error while other successful sections remain usable. An empty or malformed response is not fabricated into a populated recommendation list. A source with known animation classification can mark its items as animation without inventing title or rating data.

Metadata searches use `type=media` and do not call tracker-resource routes. The separate PT resources mode requires an explicit site selection and search action. Detail responses must retain the selected source, native ID and media type; mismatches fail rather than silently changing the selection.

Canonical source values include `themoviedb` and `douban`. The backend accepts the legacy alias `tmdb`, but the application canonicalizes it. Source and ID form a pair; optional `tmdb_id` and `douban_id` must not be interchanged. Regular media endpoints return the Chinese type values `电影` and `电视剧`; the separate `/recommend/agent` projection can return `movie` and `tv`. Convert types deliberately before a create request.

The app requires a real season selection for television. Season zero means specials and remains distinct from a missing season. Read `/media/seasons` rather than guessing a single season from a poster or title. A movie create request omits `season`.

Minimal create payload:

```json
{
  "name": "Fixture title",
  "year": "2025",
  "type": "电视剧",
  "media_source": "themoviedb",
  "media_id": "12345",
  "season": 1
}
```

Do not copy a whole recommendation response into this payload. The public write schema removes system/derived fields such as `id`, `state`, `username`, artwork, current execution state and completion facts. Omit site, downloader, path and quality overrides when using the server's existing defaults.

The existing-subscription route accepts `season` plus optional `mtype`, `title` and `year` for the backend's cross-source metadata fallback. A successful empty subscription has `id: null`; a missing ID field or malformed object is unknown and blocks creation. The create endpoint uses `exist_ok=True`, so HTTP 200 and a positive ID do not by themselves prove a newly created row.

**Creating a subscription can schedule automatic searches and downloads under MoviePilot's existing rules.** It requires the global read-only lock to be off, MoviePilot management permission, an explicit per-operation confirmation and current authorization at dispatch. It is not a read-only bookmark operation.

Before sending, persist a local intent keyed by the service/account and canonical media/season identity. Failed persistence blocks the POST. A network failure, malformed acknowledgement, business `success=false` or unconfirmed readback never automatically replays it, including after relaunch. Fresh read-only lookup may resolve a pending intent. Read back the exact subscription after acknowledgement before displaying verified success.

The persistent intent contains an identity hash, timestamp and optional confirmed subscription ID; it must not contain credentials, full service URLs or restricted links. Corrupt ledger data fails closed and is retained for review.

## Poster images

MoviePilot discovery and subscription posters use the connected MP's authenticated image-cache route. The client extracts validated public HTTPS artwork references from supported MP wrapper URLs, discards browser resource tokens and sends its own current authentication header only to its configured MP origin. It does not send service credentials to an external image host. Validate the image MIME type, file signature and 8 MiB size bound before rendering; invalid responses retain a placeholder with an explicit Retry poster action. These poster requests are separate from bundled character backgrounds and never submit subscriptions or downloads.

## Explicit PT resource search and download

Resource search is separate from metadata discovery and default-rule subscription. It runs only after the user chooses connected, enabled sites. Typing, opening a result, dashboard refreshes and refresh-frequency changes do not run tracker searches. The app reads the requested response directly and does not reuse the shared `/search/last` cache. Returned site identities must belong to the selected set.

Display the resource title, site, size, available seeder/peer counts and any known promotion or H&R information. Missing values remain unknown. A displayed Free flag does not guarantee that the download finishes before its deadline; actual traffic accounting and H&R follow the site's rules.

For an explicit download, use the chosen resource context:

```json
{
  "media_in": { "...": "selected media context" },
  "torrent_in": { "...": "selected torrent context" },
  "downloader": "the explicitly selected MP downloader name"
}
```

Omit `save_path` to retain MoviePilot's own default; include it only for an explicitly selected current preset. Each deployment supplies its own directories. Preset choices are device-local, scoped to the MP connection and revalidated against current configuration. The app does not edit server defaults.

The user-facing “Confirm downloader identity” page explains which MP downloader is the same instance as a connection in the app. For example, an MP “Main downloader” may be the same instance as the app's “Home qB1”; the user must verify that fact rather than relying on matching names. Only compatible qBittorrent or Transmission roles are offered. Hostnames may differ between MP's container network and the phone, so names or endpoint aliases must not infer authorization. A mapping includes the current MP downloader identity and expires when that identity or the local connection changes. Confirming identity is a local preference change, not a download submission.

Submission requires current MoviePilot and mapped-target permissions, the global read-only lock to be off and any migration protection to permit the target. Revalidate the selected site, downloader and preset after confirmation, then persist the download intent before the single POST. A stale result or changed connection cannot submit. The intent stores hashes, a timestamp and an optional accepted download ID, never raw resource responses or restricted URLs.

`success=true` plus `download_id` means MoviePilot accepted the task. It does not prove completion, tracker acceptance, freeleech eligibility or contractual seeding. A timeout, business failure or unknown acknowledgement never triggers automatic resubmission, including after relaunch or after selecting another downloader or directory for the same resource. Check the original service read-only before any further action.

## Foreground refresh and presentation

The device preference offers off, 15, 30, 60 or 120 seconds, defaulting to 60 seconds. The dashboard and currently visible downloader page refresh only in the foreground; entering a page and manual refresh remain available when timed updates are off. Recommendations and PT resource searches are never repeated by this timer. Concurrent dashboard refresh requests share the active cycle instead of starting overlapping reads. Background refresh state is separate from the visible manual-refresh indicator.

Routine dashboard, task-list and discovery reads have a 22-second operation budget including authentication and auxiliary requests. Explicit site searches use a separate 150-second budget because they contact selected sites. Cancellation or timeout releases the current operation without reporting missing data as zero and without automatically replaying business work. Discovery supports pull-to-refresh even when its content is empty or shorter than the screen.

Theme, text size, dashboard module visibility and Simplified Chinese / US English interface choices are device-local. English uses the `en_US` locale. Server-supplied media titles and site content keep their original text. Presentation preferences never change server configuration, action permissions or migration protection.

Character backgrounds are bundled presentation assets and enabled by default. Their device-local toggle persists across launches without changing other preferences. The five tab themes are Rem, Emilia, Ram, Beatrice and Echidna in navigation order. The system's Reduce Transparency preference suppresses decorative backgrounds; neither mode performs artwork network requests.

## Health and version discovery

`/api/v1/system/ping` is a lightweight authenticated API check. Some deployments also expose `/health/live` and `/health/ready` outside the version prefix. A reverse proxy may not forward these routes. Liveness establishes that the process handles requests; it does not establish account, tracker or download health.

`GET /api/v1/system/env` can expose broad administrator configuration and is unnecessary for routine mobile polling. Do not fetch or retain that response just to display a version number.

## References

- [MoviePilot source](https://github.com/jxxghp/MoviePilot)
- [MoviePilot API documentation](https://api.movie-pilot.org)

The implementation uses protocol observations and independent client code. No service credentials, deployment inventory or private collection receipts belong in this document.
