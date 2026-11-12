# TVcontainer server API (version 1)

SideTVstore's **Settings → TVcontainer Server** shares a user-selected list of
files with TVcontainer on the same local network. This is separate from Apple
TV pairing and app installation. No signing or pairing credentials are exposed
by the API. Only files explicitly added through the file picker are shared.

## Discovery

Browse Bonjour/DNS-SD for **`_sidetvstore._tcp`** in `local.`. Resolve each
service's host and advertised TCP port. The preferred instance name is
`SideTVstore`; Bonjour may rename it to avoid collisions. Do not hardcode the
instance name, IP, or port. The listener binds a current Wi-Fi/Ethernet IPv4
address and accepts peers only within that interface's IPv4 subnet. Cellular,
loopback, peer-to-peer Wi-Fi, IPv6-only networks, and remote networks are not
supported by this first server version. It does not create router mappings.

TXT records:

| Key | Value |
| --- | --- |
| `app` | `SideTVstore` |
| `api` | `1` |
| `protocol` | `http` |
| `path` | `/v1/files` |

The service uses ordinary HTTP/1.0 or HTTP/1.1 over TCP. There is no TLS or
authentication in version 1: files are available to other devices on that local
network while the toggle is enabled. TVcontainer should show the server name
and let its user choose a file, rather than downloading/executing files just
because a service advertises itself. Discovery itself is not authentication.

## List files

`GET /v1/files` returns `200` with `Content-Type: application/json; charset=utf-8`:

```json
{
  "version": 1,
  "files": [
    {
      "id": "5C70B0D6-CAFC-4FDB-86D4-1AA24BA97DD3",
      "name": "Example.ipa",
      "size": 50000000,
      "contentType": "application/octet-stream",
      "downloadPath": "/v1/files/5C70B0D6-CAFC-4FDB-86D4-1AA24BA97DD3"
    }
  ]
}
```

IDs are opaque UUIDs. Names are display text, not paths; do not concatenate a
filename into a request or use an unvalidated name as a client filesystem path.
Resolve `downloadPath` against the discovered server origin and require the
same origin. Empty lists are valid. Re-fetch the catalog after reconnection,
removal, or a `404`; the selected file may no longer exist.

## Download files

`GET /v1/files/{id}` streams the selected file with `Content-Length`,
`Content-Type`, `Content-Disposition: attachment`, and `Accept-Ranges: bytes`.
`HEAD` is supported for both catalog and file endpoints without a response body.

For resumable downloads, send one `Range` header such as `bytes=1048576-`,
`bytes=0-65535`, or `bytes=-65536`. A satisfiable range returns `206` with
`Content-Range: bytes start-end/total`. An invalid/unsatisfiable range returns
`416` and `Content-Range: bytes */total`. Multiple ranges are unsupported.
Honor the returned status, total length, and range before appending to an
existing download; a fresh `200` response must replace, not append to, it.

Responses use `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, and
`Connection: close`. Open a new connection for each request. HTTP pipelining,
request bodies, remote upload/delete, and WebSockets are unsupported. Other
methods return `405`; malformed requests return `400`; unknown paths/IDs
return `404`. Headers are limited to 16 KiB, header reception to 15 seconds,
and each network send to 30 seconds. At most four connections are accepted.
Large files are streamed in 64 KiB chunks, rather than loaded into memory.

## Lifetime and files

The toggle is **off on every process launch**. It also switches off when the
app enters the background. Returning to the foreground does not restart it.
SideTVstore does not start audio, location updates, an extended background
task, or an idle-timer override for this server. If iOS suspends the app or a
network connection fails, TVcontainer must handle the interruption and wait
for the user to restart the server. Bonjour advertisements are withdrawn when
the listener stops; the port may differ on the next start.

The picker copies regular files into private application storage. The list
persists, but the enabled state does not. Swipe left to remove a file; removal
ends existing downloads and never deletes the original picked file. Turning
the server off cancels all connections immediately. There is no automatic
restart or download replay. Keep the iPhone app foregrounded during transfer.

The TVcontainer client must implement this contract; advertising the service
does not add discovery to an older TVcontainer build. Discovery and complete
large-file transfers still need physical-device validation with that client,
including LiveContainer-hosted SideTVstore.

## LiveContainer startup and discovery (build 0704)

The TCP listener starts independently of Bonjour. Only after the socket is
ready does a main-run-loop `NetService` publisher advertise `_sidetvstore._tcp`.
A registration failure leaves HTTP running and displays the Bonjour error
separately. TCP failures and startup timeouts now retain their actual error
details instead of treating every failure as denied local-network permission.

Inside LiveContainer, the host's local-network authorization and permitted
Bonjour service declarations can differ from the guest's. If the host blocks
the custom service, SideTVstore cannot change that installed host policy.
Use the displayed LAN address, or long-press a shared file and choose **Copy
Download Link** or **Share**. Automatic discovery requires a host configuration
that permits `_sidetvstore._tcp` in `NSBonjourServices`. This is separate from
granting general Local Network access; see Apple's
[local-network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The Settings entry is a standard SideStore inset button directly below Account,
with the title **TVcontainer** and description **Send IPAs and P12 certificates
directly to TVContainer**. The server still stops on backgrounding and starts
off on every launch. No background execution or audio workaround is used.
