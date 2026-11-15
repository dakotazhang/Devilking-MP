# MoviePilot API contract

This document describes the MoviePilot API conventions used by the 1.1.0 redesign branch. Discovery, identity lookup and season contracts were checked against current backend source and authenticated read-only responses on 2026-11-15. Live subscription creation was not exercised. Build, fixture and physical-device results are recorded separately; this branch is undergoing private testing and has not been publicly released.

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
| Recommendation sections | GET `/api/v1/recommend/douban_showing`, `/douban_movies`, `/douban_tvs`, `/douban_tv_animation` | Media lists, bounded `page` and `count` |
| Native media detail | GET `/api/v1/media/{media_id}?media_source=...&type_name=...` | One media object |
| TV season selection | GET `/api/v1/media/seasons?media_source=...&media_id=...&type_name=电视剧` | Season objects including `season_number` |
| Existing subscription | GET `/api/v1/subscribe/media/{media_id}?media_source=...` | Subscription or an empty subscription object with null `id` |
| Create one subscription | POST `/api/v1/subscribe/` | Success envelope with `data.id`; a live server may return an existing identity |

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

The application reads four bounded recommendation sections: Douban showing, movies, TV and animation. A failed section keeps an explicit error while other successful sections remain usable. An empty or malformed response is not fabricated into a populated recommendation list. A source with known animation classification can mark its items as animation without inventing title or rating data.

Search requests use `type=media`. They do not call tracker-resource search routes. Detail responses must retain the selected source, native ID and media type; mismatches fail rather than silently changing the selection.

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

## Health and version discovery

`/api/v1/system/ping` is a lightweight authenticated API check. Some deployments also expose `/health/live` and `/health/ready` outside the version prefix. A reverse proxy may not forward these routes. Liveness establishes that the process handles requests; it does not establish account, tracker or download health.

`GET /api/v1/system/env` can expose broad administrator configuration and is unnecessary for routine mobile polling. Do not fetch or retain that response just to display a version number.

## References

- [MoviePilot source](https://github.com/jxxghp/MoviePilot)
- [MoviePilot API documentation](https://api.movie-pilot.org)

The implementation uses protocol observations and independent client code. No service credentials, deployment inventory or private collection receipts belong in this document.
