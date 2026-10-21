# Library, tags and the classical ontology

## Schema (Core Data, built in code — no `.xcdatamodeld`)

```
Track ──< Credit >── Party              multi-valued: any number of artists, composers, conductors, ensembles, soloists… per track
Track >── Release                       album / disc
Track >── Work ──< Movement ──< Track   Work: title, catalogue number (Op. 67, BWV 1068, K. 550…), key, composer (Party)
Track >──< Genre
Change (seq, revision, kind, uid, op)   append-only log for remote sync
```

* `Credit.role` ∈ artist, albumArtist, composer, conductor, ensemble, soloist, performer, lyricist, arranger, producer, engineer, remixer;
  `Credit.instrument` for soloists/performers; `Credit.order` keeps the tag order.
* `Party` is one row per person or group (merged by MusicBrainz id, else by case/diacritic-folded name). `kind` is `group` for ensembles.
* A track's credits are replaced as a whole when its file is re-tagged; parties/works/releases left with no tracks are pruned.
* Every synced entity has a stable `uid` (UUID string).
* The store uses SQLite on disk, and an in-memory SQLite store (`/dev/null`) in tests so predicates compile exactly as in production.
  (SwiftData's `@Model` macro needs full Xcode; Core Data does not.)

## Reading tags

Both readers are synchronous, dependency-free and never decode audio.

**FLAC** — Vorbis comments. Keys are case-insensitive and normalised (spaces/underscores ignored), every value is kept in file order,
repeated keys are multiple values.

**ALAC / AAC (MP4)** — `moov/udta/meta/ilst` atoms: `©nam ©ART aART ©alb ©day ©wrt ©gen ©grp trkn disk`, Apple's classical atoms
`©wrk` (work) `©mvn` (movement name) `©mvi` (number) `©mvc` (count), `©con` (conductor), and iTunes free-form `----` atoms
(`CONDUCTOR`, `ENSEMBLE`, `PERFORMER`, `OPUS`, `MusicBrainz Track Id`, …), where several `data` children are several values.

| Meaning | Vorbis key(s) | MP4 |
|---|---|---|
| Artist(s) | `ARTIST` (repeat), `ARTISTS` | `©ART` (several `data`) |
| Composer | `COMPOSER` | `©wrt` |
| Conductor | `CONDUCTOR` | `©con`, `----:CONDUCTOR` |
| Ensemble | `ENSEMBLE`, `ORCHESTRA`, `CHOIR` | `----:ENSEMBLE` |
| Soloists / performers | `PERFORMER=Name (instrument)`, `SOLOIST` | `----:PERFORMER` |
| Work | `WORK`, `WORKNAME`, (`GROUPING` with movement tags) | `©wrk` |
| Movement | `MOVEMENT` (`2/4` or roman), `MOVEMENTNAME`, `MOVEMENTTOTAL` | `©mvi ©mvn ©mvc` |
| Catalogue no. | `OPUS`, else parsed from the work title | `----:OPUS` |
| MusicBrainz ids | `MUSICBRAINZ_TRACKID/ALBUMID/RELEASEGROUPID/ARTISTID/WORKID` | free-form atoms |

Interpretation rules: `;` and ` / ` (with spaces) split a single value into several people — `AC/DC` and `Earth, Wind & Fire` do not;
`PERFORMER` values with an annotation become soloists (instrument) or conductors/ensembles (role words); a work and movement are
*inferred* from titles like `Symphony No. 5, Op. 67: II. Andante` only when a composer tag exists (`workInferred` marks them).
Catalogue numbers recognised: Op., opus, BWV, K./KV, D., Hob., RV, HWV, WoO, TrV, Sz, Wq.

## Browsing

Composer → Works → Recordings → Movements; a recording is one release's tracks of a work, listed with conductor, ensemble and
soloists, oldest first. Artists, conductors, ensembles and albums browse straight to tracks. Search is case- and diacritic-insensitive
(`dvorak` finds Dvořák).
