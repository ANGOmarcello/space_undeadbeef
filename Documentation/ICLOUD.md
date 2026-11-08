# iCloud progress

## Sideloaded iPhone and iPad builds

1. In Files, create a dedicated **Space Deadbeef** folder in **iCloud Drive**.
2. In the game, open **Options → iCloud Progress → Choose iCloud Drive Folder**.
   Select that folder. Use the same folder on every device you want to share with.
3. Return to the title screen to see incoming progress. Use **Sync Now** in
   iCloud Progress to check immediately.

Linking a folder starts optional sharing. **Disconnect** stops it and retains
both your local save and the existing shared files. Local progress saves even
when the folder is unavailable. If Files access changes, select the folder again.
Keep separate folders for separate players; progress in a shared folder combines.

The furthest valid checkpoint wins and the high score never decreases. Incoming
progress is applied at the title screen. Audio, game speed, haptics and other
settings remain local. A current run is never replaced mid-game. This does not
sync resets or deletions, or save an exact position between checkpoints.

Like [Peggle's public build](https://github.com/DylanMcD8/respring-peggle/blob/revision-2/docs/ICLOUD.md),
the app remembers Files-granted folder access and leaves delivery to iCloud Drive.
It needs no CloudKit database, app-owned iCloud container, or shared signing team.
The file format is specific to Space Deadbeef; don't choose a folder expecting
it to import Peggle saves. **Last checked** means the app exchanged records with
the locally accessible folder, not that another device has received them.

## Personal builds

The normal schemes retain their existing provisioned iCloud key-value progress
exchange. The sideload configuration uses the folder transport instead. The two
transports do not copy records to one another; both use the same local save
format. Mac, TV and Watch retain their existing local saves and optional
provisioned sync. The Files picker is available in the iPhone/iPad sideload build.

## File contract

The host checks on activation, at checkpoints while active, and on return to the
title. File operations are coordinated on a background worker. Each installation
has one `SpaceDeadbeef-Save-<UUID>.json` writer, with its identifier excluded from
backup. Records are versioned and checksummed. Only the understood checkpoint,
score and related scenario fields from the original save are shared. The local
save transaction and the game's original loading code remain in charge of import.

The exchange validates all recognized records before publishing. It bounds
directory enumeration, file counts and actual reads, rejects symlinks and
invalid records, requests placeholder downloads and includes readable conflict
versions without deleting them. Only the current installation's writer file is
replaced. The host rechecks it under a write claim before atomic replacement.
Unchanged data is not republished. Other files and devices' records are left alone.

Two-writer tests exercise this file exchange and the real PSH0 validator using
temporary local folders. The simulator test verifies the actual Options control,
Files picker and cancellation. Cross-device iCloud Drive delivery still needs a
test with two signed installations and an available iCloud account.
