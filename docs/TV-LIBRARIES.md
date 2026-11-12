# Per-TV app libraries (build 0703)

My Apps has a TV-name menu above the app list. Select a saved Apple TV to view
its library; the green/red connection dot appears beside that name. Switching
does not uninstall anything or empty either library. A running app operation
must finish before the selected TV can change. An offline library remains
available if reconnection fails.

Each installed record is owned by its pairing UUID, not its device UDID.
Refresh All, update lookups, removals, custom profile assignments, and caches
use that ownership. Source and release-track relationships allow multiple
installed records, so the same source app can exist in several TV libraries.
Operations reject an installed record belonging to a different selected TV.

## Upgrade

The 17_8 Core Data model assigns the old library to its formerly bound TV.
Existing files stay at their old paths. New installations use per-library
directories. Content-addressed original payloads remain shared and are kept
while any library references them. Previously unassigned records are adopted
by the first selected TV. Forget Pairing still requires removing that TV's
tracked records, to avoid orphaning a library; switching libraries does not.

The default source changes to
https://raw.githubusercontent.com/hubzzzgr/sideloading-source/main/source.json.
The old default source is migrated in place, keeping its installed references.
Launch requests bypass the local URL cache. A failed refresh keeps the saved
catalog. User-added sources are retained.

CI checks the old-to-new database migration, duplicate bundle IDs on separate
TVs, shared catalog/track relationships, scoped generic and registered-object
lookups, isolated removal, and distinct cache paths. Physical multi-TV update,
refresh, removal, and migration still need validation. Prior single-TV testing
does not establish these new behaviors.
