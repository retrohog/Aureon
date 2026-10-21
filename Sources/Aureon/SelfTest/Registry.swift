// Additional suites register here.
func extraTests() -> [(String, TestFn)] {
    var t: [(String, TestFn)] = []
    let d = DSDTests()
    t += [("dsd.dsfDoPExact", d.dsfParsesAndDoPPacksExactly), ("dsd.dffEqualsDsf", d.dffAndDsfGiveIdenticalBits),
          ("dsd.dopMarkerContinuity", d.dopMarkerContinuesAcrossTracks), ("dsd.toPcmSignal", d.dsdToPcmRecoversTheSignal),
          ("dsd.toPcmSeek", d.dsdToPcmSeekIsDeterministic), ("dsd.badRatios", d.rejectsBadRatios)]
    let r = ReplayGainTests()
    t += [("replaygain.parseVorbis", r.parsesVorbisReplayGain), ("replaygain.resolution", r.resolutionRules),
          ("replaygain.loudnessEBU", r.loudnessMatchesEBUReference), ("replaygain.measuredGain", r.measuredGainTargetsMinus18)]
    let s = StageTests()
    t += [("stages.gain", s.gainStage), ("stages.ram", s.memoryTrackIsExactAndBudgeted)]
    let cf = CrossfeedTests()
    t += [("crossfeed.design", cf.design), ("crossfeed.symmetryBlocks", cf.symmetryAndBlockInvariance), ("crossfeed.stable", cf.staysStable)]
    let hp = HeadphoneEQTests()
    t += [("autoeq.parse", hp.parsing), ("autoeq.responses", hp.filterResponsesAreExact), ("autoeq.realtime", hp.realTimeProcessorMatchesTheResponse),
          ("autoeq.preamp", hp.preampProtectsAgainstClipping), ("autoeq.index", hp.indexParsingAndSearch), ("autoeq.catalog", hp.catalogFetchesOnceAndCaches)]
    let cv = ConvolutionTests()
    t += [("convolution.delta", cv.deltaIsIdentityDelayedByOneBlock), ("convolution.direct", cv.matchesDirectConvolution),
          ("convolution.callbackSizes", cv.callbackSizeDoesNotMatter), ("convolution.stereo", cv.stereoUsesOneIrPerChannel),
          ("convolution.response", cv.frequencyResponseOfASimpleFilter), ("convolution.wav", cv.wavReaderHandlesRewStyleFiles),
          ("convolution.resample", cv.trimmingAndResamplingKeepTiming), ("convolution.normalize", cv.normalizationPreventsBoost),
          ("convolution.speed", cv.longIRRunsMuchFasterThanRealTime)]
    let tp = TagParserTests()
    t += [("tags.vorbis", tp.vorbisKeepsEveryValueInOrder), ("tags.mp4", tp.mp4AtomsAndFreeformTags),
          ("tags.realFLAC", tp.realFLACWithInjectedTagsStillDecodesIdentically), ("tags.realALAC", tp.realALACWithInjectedAtomsStillDecodesIdentically)]
    let ti = TagInterpreterTests()
    t += [("tags.multiArtist", ti.multipleArtistsAreSplitSafely), ("tags.classical", ti.fullClassicalTags), ("tags.inference", ti.workAndMovementAreInferredConservatively),
          ("tags.catalog", ti.catalogueNumbers), ("tags.roman", ti.romanNumeralsAndLeadingMovements), ("tags.mp4Classical", ti.mp4ClassicalAtomsInterpret)]
    let sy = SystemTests()
    t += [("system.machPolicy", sy.machTimeConstraintPolicy), ("system.ioCycle", sy.ioCycleUsageOnTheDefaultDevice), ("system.suspendAllowlist", sy.suspendsOnlyAllowlistedProcesses),
          ("system.neverLaunchd", sy.neverTouchesLaunchdOrItself), ("system.notOurs", sy.doesNotResumeWhatSomeoneElseStopped), ("system.crashRecovery", sy.recoversAfterACrash),
          ("system.watchdog", sy.watchdogResumesWhenTheAppGoesSilent), ("system.dealloc", sy.deallocatingTheServiceResumes), ("system.xpc", sy.xpcRoundTrip),
          ("system.quietMode", sy.quietModeLifecycle), ("system.quietFailures", sy.quietModeFailuresAreHarmless), ("system.hooks", sy.playerCallsTheTuningHooks)]
    let dm = DaemonTests()
    t += [("daemon.process", dm.daemonProcessEndToEnd), ("daemon.launchAgent", dm.launchAgentPlistIsWellFormed), ("daemon.token", dm.tokenFileIsStable), ("daemon.nullSink", dm.nullSinkPlaysInRealTime)]
    let rm = RemoteTests()
    t += [("remote.protocol", rm.protocolAuthentication), ("remote.queue", rm.controllerQueueAndErrors), ("remote.settings", rm.controllerSettings),
          ("remote.transport", rm.controllerTransport), ("remote.library", rm.controllerLibrary), ("remote.artwork", rm.artworkThumbnails),
          ("remote.auth", rm.authenticationOverTheSocket), ("remote.twoClients", rm.twoClientsStayInSync), ("remote.status", rm.statusIsPushedDuringPlayback),
          ("remote.concurrent", rm.manyConcurrentCalls), ("remote.mirror", rm.libraryMirrorConverges), ("remote.stop", rm.serverStopDisconnectsClients)]
    let aw = ArtworkTests()
    t += [("art.id3v23", aw.id3v23FramesAndPicture), ("art.id3v24v22", aw.id3v24AndV22), ("art.id3hostile", aw.truncatedAndHostileTagsDoNotCrash),
          ("art.flacFields", aw.flacAlbumTrackYearGenreAndHiResCover), ("art.flacPictures", aw.flacPictureTypesAndBase64Comment), ("art.flacLeadingID3", aw.flacBehindALeadingID3Tag),
          ("art.alac", aw.alacCoverAndAtoms), ("art.wavAiff", aw.wavAndAiffID3Chunks), ("art.untagged", aw.untaggedFilesAreHandledGracefully),
          ("art.matching", aw.matchingRules), ("art.itunes", aw.iTunesHitIsUpscaledAndCached), ("art.musicBrainz", aw.fallsBackToMusicBrainzAndCoverArtArchive),
          ("art.rejects", aw.rejectsWrongMatchesAndRemembersNothingFound), ("art.offline", aw.offlineIsNotRemembered), ("art.dedupe", aw.concurrentRequestsForOneAlbumShareOneLookup),
          ("art.tooSmall", aw.tooSmallImagesAreSkipped)]
    let ui = InterfaceTests()
    t += [("ui.palette", ui.paletteFollowsTheCover), ("ui.paletteEdge", ui.greyAndTinyImagesAreSafe), ("ui.signalPath", ui.signalPathStations), ("ui.quality", ui.qualityTiers), ("ui.navigation", ui.navigationStructure)]
    let dc = DiscordTests()
    t += [("discord.quality", dc.qualityLabels), ("discord.text", dc.textRules), ("discord.presence", dc.presenceBuilder), ("discord.frame", dc.frameEncoding),
          ("discord.socket", dc.handshakeAndActivityOverARealSocket), ("discord.notRunning", dc.discordNotRunning), ("discord.errors", dc.discordErrorsAreSurfaced),
          ("discord.reconnect", dc.reconnectsWhenDiscordRestarts)]
    let ss = ScrobbleServiceTests()
    t += [("scrobble.lastfmSignature", ss.lastfmSignature), ("scrobble.lastfmRequests", ss.lastfmRequests), ("scrobble.lastfmErrors", ss.lastfmErrorMapping),
          ("scrobble.lastfmSignIn", ss.lastfmSignIn), ("scrobble.listenbrainz", ss.listenbrainz)]
    let st = ScrobbleTrackerTests()
    t += [("scrobble.threshold", st.thresholdRule), ("scrobble.rule", st.scrobblesAtHalfOrFourMinutes), ("scrobble.pauseSeek", st.pausingAndSeekingDoNotCount),
          ("scrobble.repeats", st.changingTracksAndRepeats), ("scrobble.gaps", st.gapsAndMissingTags)]
    let sq = ScrobbleQueueTests()
    t += [("scrobble.queue", sq.persistsAndSends), ("scrobble.backoff", sq.temporaryFailuresBackOff), ("scrobble.rejected", sq.permanentRejectionsAreDropped),
          ("scrobble.authQueue", sq.authProblemsKeepEverything), ("scrobble.batching", sq.oldPlaysAndBatching), ("scrobble.secrets", sq.secretStoreRoundTrip)]
    let md = MetadataTests()
    t += [("metadata.recording", md.recordingParsing), ("metadata.artist", md.artistParsing), ("metadata.acoustidParse", md.acoustidParsing),
          ("metadata.mbClient", md.musicBrainzClientBehaviour), ("metadata.rateLimit", md.rateLimiterSpacesRequests), ("metadata.acoustidClient", md.acoustidClientRequest),
          ("metadata.wikipedia", md.wikipediaAndCoverArt), ("metadata.flowTags", md.deepDiveFromFileTags), ("metadata.flowFingerprint", md.deepDiveByFingerprint),
          ("metadata.missingTools", md.missingToolsAreExplained), ("metadata.bioFailure", md.artistBioFailureIsNotFatal), ("metadata.cover", md.chooseCoverRules)]
    let lb = LibraryTests()
    t += [("library.classical", lb.classicalOntology), ("library.multiValued", lb.multiValuedCredits), ("library.retag", lb.reTaggingReplacesCreditsAndPruning),
          ("library.changeLog", lb.changeLogDrivesSync), ("library.search", lb.searchFoldsCaseAndDiacritics), ("library.persist", lb.persistsOnDisk),
          ("library.import", lb.importFolderEndToEnd)]
    let ri = RTIntegrationTests()
    t += [("rt.crossfeed", ri.crossfeedThroughThePlayer), ("rt.status", ri.statusReportsTheChainAndBitPerfectFlag),
          ("rt.liveToggle", ri.switchingOnAndOffMidPlaybackIsClean), ("rt.headphoneEQ", ri.headphoneEQThroughThePlayer),
          ("rt.convolution", ri.convolutionThroughThePlayer), ("rt.irRate", ri.impulseResponseAtAnotherRateIsConverted),
          ("rt.formatChange", ri.filtersAreRebuiltAtAFormatChange), ("rt.errors", ri.unsupportedCombinationsAreReportedNotCrashed),
          ("rt.oldSettings", ri.oldSavedSettingsStillDecode)]
    let rcu = RCUTests()
    t += [("rcu.basics", rcu.basics), ("rcu.stress", rcu.readerNeverSeesFreedObjects)]
    let an = AnalysisTests()
    t += [("analysis.spectrum", an.spectrumLevelAndFrequency), ("analysis.twoTones", an.twoTonesAreSeparated),
          ("analysis.spectrogram", an.spectrogramShowsTheToneInTheRightRow), ("analysis.vu", an.vuCalibrationAndBallistics),
          ("analysis.peakHold", an.peakHoldAndClip), ("analysis.metersFall", an.metersFallWhenAudioStops),
          ("analysis.tapNonBlocking", an.tapNeverBlocksAndIsFreeWhenDisabled), ("analysis.mono", an.monoStreamsAreMirrored),
          ("analysis.livePlayer", an.livePlayerFeedsTheAnalyser)]
    let dsp = DSPTests()
    t += [("dsp.eqBoost", dsp.parametricBoostHitsTheTargetFrequencyOnly), ("dsp.cutShelf", dsp.cutAndShelfBehave),
          ("dsp.transparentEQOff", dsp.dspPathIsTransparentWithEQOff), ("dsp.autoPreamp", dsp.autoPreampPreventsClipping),
          ("dsp.liveToggle", dsp.switchingDSPOffMidPlaybackReturnsToTheDirectPath), ("dsp.audioUnit", dsp.hostsAnAudioUnitPlugin)]
    let pl = PlayerTests()
    t += [("player.gapless", pl.gaplessIsBitExact), ("player.flac", pl.flacDeliversExactSamples), ("player.formatChange", pl.formatChangeStartsNewGroup),
          ("player.skipUnreadable", pl.unreadableFileIsSkipped), ("player.pause", pl.pauseHoldsAndResumes), ("player.seek", pl.seekRepositionsAndPositionTracks),
          ("player.nextJump", pl.nextAndJumpRestartAtTheRightTrack), ("queue.removeUpcoming", pl.removeBufferedUpcomingTrack),
          ("queue.reorderUpcoming", pl.reorderBufferedUpcomingTracks), ("queue.insertAppend", pl.insertAndAppendWhilePlaying),
          ("queue.removePlaying", pl.removeThePlayingTrackAdvances), ("queue.clear", pl.clearingTheQueueStops),
          ("ram.identicalNoDisk", pl.ramPlaybackIsIdenticalAndStopsDiskReads), ("ram.prefetchNext", pl.ramPrefetchesTheNextTrack),
          ("player.upsample", pl.upsamplingReachesTheDeviceMaximum), ("player.fitRate", pl.unsupportedRateIsBroughtDownByUs),
          ("player.nativeBitPerfect", pl.nativeRateStaysBitPerfect), ("player.replayGain", pl.replayGainLevelsUntaggedFiles),
          ("player.polarity", pl.polarityInversionNegatesSamples), ("player.liveSettings", pl.settingsChangeAppliesWithoutLosingPlace),
          ("player.dsdDoP", pl.dsdPlaysAsDoPWithContinuousMarkers), ("player.dsdFallback", pl.dsdFallsBackToPcmWhenDeviceCannotDoP)]
    return t
}
