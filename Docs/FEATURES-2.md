# Aureon 0.3: ripping, loudness, multichannel, extreme rates, converting, cloud, casting

How each subsystem works and where its limits are. Source folders are named in brackets.

## Loudness [Loudness/, Pipeline/ReplayGain.swift]
BS.1770-4: K-weighting (two biquads per channel, double precision, `vDSP_deq22D`), 400 ms blocks every 100 ms, absolute gate −70 LUFS and relative gate −10 LU,
channel weights (surrounds +1.5 dB, LFE excluded), loudness range per EBU Tech 3342, true peak with a 4× (2× above 96 kHz, 1× above 192 kHz) windowed-sinc
oversampler, DR from 3-second blocks. It follows the EBU Tech 3341 test signals. Results are cached in the library (`lufs`, `truePeakDB`, `lra`, `dr`)
and recomputed when the file changes.

## Multichannel [Pipeline/Multichannel.swift]
Channel layouts are read from the file and the device as speaker labels. `ChannelRouter` maps source speakers to device outputs; with too few outputs
`Downmix` builds an ITU-R BS.775 matrix (centre −3 dB, surrounds −3 dB, LFE dropped unless asked). A mismatch between DSD channels and outputs switches DoP to PCM.

## Extreme rates [Pipeline/DSDFast.swift, Engine/Performance.swift]
DSD is decimated by a byte-lookup FIR followed by halfband stages, so DSD1024 at 49 MHz converts faster than real time. `PerformanceProfile` times the
resampler and decimator once at start-up and answers "can this Mac sustain X in real time with headroom?"; the player asks it before choosing a rate and falls back
(with a line in the signal path) instead of underrunning.

## CD ripper [Ripping/, Library/TagWriter.swift]
`CDSource` is either an IOKit drive (`DKIOCCDREAD`, raw sectors with C2 pointers) or a BIN/CUE image. `DiscRipper` reads each sector until two reads agree
(more reads, cache flush, majority vote), treats C2 flags as a reason to re-read, applies the read offset, and reports every sector it could not settle.
Disc IDs (MusicBrainz, CDDB, AccurateRip) and AccurateRip v1/v2 checksums were checked against real discs; the database answer is parsed and each track gets
"accurate (confidence n)". Output: FLAC / ALAC / WAV with tags and cover, a CUE sheet and a log.

## Converter [Transcode/]
Per file: decode → (measure loudness → gain limited by the true-peak ceiling) → optional sample-rate conversion (AVAudioConverter, mastering quality; AAC is capped at 48 kHz)
→ encode with AVAudioFile (AAC 256 kbps constant, ALAC, FLAC; TPDF dither when a 16-bit file gets a gain) → write tags and cover. Files run on up to cores−1 threads.
Output is written to a hidden `.partial` file and moved into place, so a cancelled or failed conversion never leaves a half file.

## Cloud and servers [Cloud/, Streaming/]
`S3Client` signs with SigV4 (checked against Amazon's published vectors). `ChunkedReader` is the heart: 1 MiB chunks, up to four in flight, a look-ahead set in
seconds of audio from the file's bit rate, back-off retries, a bounded cache that always keeps the first and last chunks, and `warm()` for the next track. It
backs an `AudioFileOpenWithCallbacks` file, so CoreAudio decodes straight from the bucket. Library tracks get `cloud://profile/key` or `subsonic://profile/id.ext`
paths and play, analyse, show covers and get queued like local files. The importer skips unchanged objects and removes tracks that left the bucket.

## Casting [Cast/]
`CastOutput` runs a pacing thread that pulls from the player's `Renderer` (the processed output), encodes it with `LiveFLACEncoder` (CONSTANT / FIXED 0–4 /
VERBATIM subframes, Rice partitioning; verified bit-exact against CoreAudio's decoder) and publishes frames to a `LiveStreamHub`; `StreamServer` serves them over
HTTP; `CastController` speaks CASTV2 to the speaker (CONNECT, LAUNCH the Default Media Receiver, LOAD a LIVE stream, heartbeat, volume). The pacing thread
sends silence while nothing plays so the speaker never has to reload. The sink declares a fixed rate and the player resamples every track to it.

