# An app that holds sensitive data (Flutter)

Apply only when the app stores data its user would not want read off a lost phone, a backup or the network:
financial, health, identity. Checked against https://pub.dev/packages/sqlite3 and its hook documentation,
https://pub.dev/packages/sqlcipher_flutter_libs and https://developer.android.com/identity/data/autobackup
(2026-10-07). The iOS part is from Apple's API names and was **not checked against a fetched page**.

## The database is encrypted
- The project's database package decides how; the rule is that the file on disk is ciphertext.
- With `package:sqlite3` 3.x the SQLite build is chosen by a build hook, in the `pubspec.yaml` at the workspace root:

  ```yaml
  hooks:
    user_defines:
      sqlite3:
        source: sqlcipher   # or sqlite3mc; the default is sqlite3, which does not encrypt
  ```

- `sqlcipher_flutter_libs` belongs to version 2.x of `package:sqlite3`; its own page says "Not used anymore, update
  to version 3.x of package:sqlite3 instead". Do not add it to a project on 3.x.
- A test opens the database file without the key and expects the open to fail: an encryption that was configured
  and silently not applied looks the same from the app.

## The key is in the platform's secure store
- Generated on the device, kept in the Keychain (iOS) or behind the Keystore (Android) through the project's
  secure-storage package. Not in the database's directory, not in shared preferences, not in the code or its assets.
- A key that is lost makes the data unreadable. Decide and write down what the app does then (an `adr`).

## Out of backup and device transfer
The database and the secure store's own files are excluded on both platforms; a restored copy without its key is
unreadable at best, and a copy with its key is the data on another device.

- **Android.** `android:allowBackup="false"` on `<application>`. For an app that targets Android 12 (API 31) or
  higher that turns off cloud backup but, in the documentation's words, "doesn't disable device-to-device transfers"
  on some manufacturers' devices. So also `android:dataExtractionRules` pointing at an XML file whose
  `<cloud-backup>` and `<device-transfer>` sections each exclude the database and the secure-storage files. Devices
  on Android 11 or lower read `android:fullBackupContent` instead.
- **iOS.** The files carry the resource value `isExcludedFromBackup` (`NSURLIsExcludedFromBackupKey`), set from
  native code or a plugin after the file exists. Set it again when the file is created anew.
- A test (or a check in CI) reads the manifest and the rules file and fails when either attribute is missing.

## Every network call through a transport bound to its allowed hosts
- A transport is the one object a service's requests leave through. Each holds the host or hosts **it** may talk
  to and **refuses any other**: it throws before the request is sent. An app with one backend has one transport;
  an app that talks to several services gives each its own, with its own list, so a transport for one service
  cannot reach another's host.
- A test asks each transport for a host that is not on its list and expects the throw. An architecture test fails
  on a network call made outside a transport (a client constructed or a socket opened anywhere else). In a debug
  run the throw is a crash someone sees; it is never swallowed.

## Ads
In an app that shows ads, **no ad is drawn in a window where a sensitive screen is visible.** In a two-pane layout
the detail pane may be the sensitive one while the list is not: the rule is about the window, so the list's ad goes
too. A widget test at an expanded width expects no ad widget while the sensitive detail is shown.
