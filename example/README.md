# ReaxDB example

A Flutter application that demonstrates the ReaxDB 2.0 API, one screen per
feature. Each screen states what it shows, lists the calls it is built from,
and then does exactly that against a real database on the device.

## Running it

```bash
cd example
flutter pub get
flutter run
```

The example depends on the package through a path dependency (`../`), so it
always runs against the source in this repository. It uses `dart:io`, which
means Android, iOS, macOS, Windows and Linux — not Flutter Web.

Databases are created under the application documents directory, in
`reaxdb_example/<demo>`. Every demo owns its own directory, so no two demos
contend for the same on-disk lock, and each closes its database when its
screen is popped.

## What each screen demonstrates

| Screen | API |
| --- | --- |
| Overview | `ReaxDB.open`, `info()`, `statistics()`, `cacheStats`, `storageStats`, `flush()`, `compact()`, `schemaVersion` with `onUpgrade` |
| Key/value basics | `ReaxDB.simple`, `SimpleReaxDB.put/get/putAll/getAll/query/watch` |
| Typed collections | `db.collection<T>(fromJson:, toJson:)`, compound `createIndex`, `find`, `watch` |
| Iteration and scans | `scan`, `scanPrefix`, `keys`, `range`, `limit`, `reverse` |
| Expiring entries | `put(ttl:)`, `ReaxEntry.expiresAt`, `purgeExpired()` |
| Transactions | `transaction()`, `IsolationLevel.serializable`, rollback on throw, `compareAndSwap` |
| Backup and restore | `exportTo`, `ReaxDB.importFrom` into an AES-256 database, checksum rejection of a damaged archive |
| Durability modes | `SyncMode.none / os / full` measured on the device, and the per-write `sync:` override |
| Todo list | reverse prefix scans plus `watchPrefix` change streams |
| Chat | an append-only log rendered from a change stream, without polling |

The Overview screen also runs a real schema migration: it creates a scratch
database at version 1, reopens it at version 2 and shows the `onUpgrade`
callback rewriting the stored documents.

## Notes on the demos

- **Durability.** The durability screen measures how long writes take under
  each `SyncMode`. It measures the cost of durability, not durability itself:
  only killing the process or cutting power demonstrates what each mode
  actually survives, and the screen says so.
- **Encryption.** The demo databases are not encrypted, so the app starts
  quickly. The backup screen shows real encryption: it restores an archive
  into a database opened with `EncryptionConfig.aes256`, using a freshly
  generated 256-bit key. ReaxDB 2.0 never derives a key from a database name;
  encryption always takes real key material through an `EncryptionConfig`.

## Tests

```bash
cd example
flutter analyze
flutter test
```

- `test/database_service_test.dart` exercises the ReaxDB calls the screens are
  built from against real files in a temporary directory: typed collections
  and compound indexes, ordered scans, TTL, transactions and rollback,
  export/import, schema upgrades, locking and key validation.
- `test/screens_smoke_test.dart` mounts every demo screen against a temporary
  database on a phone-sized surface, then unmounts it: each screen has to
  open, lay out without overflowing, and dispose cleanly. It also drives the
  iteration demo's buttons and checks the output they produce.
- `test/widget_test.dart` covers the catalogue and the shared widgets.
