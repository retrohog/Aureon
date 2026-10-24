// Additional suites register here.
func extraTests() -> [(String, TestFn)] {
    var t: [(String, TestFn)] = []
    t += powerFeatureTests()
    t += naturalPlaylistTests()
    t += lyricsTests()
    t += stageInteractionTests()
    t += navigationTests()
    t += controlTests()
    t += nowPlayingTests()
    t += qualityBadgeTests()
    t += analyserTests()
    t += backdropGlassTests()
    t += soundQuickTests()
    t += appearanceTests()
    t += tabSwitchTests()
    t += splashTests()
    t += feedbackTests()
    t += levelEntryTests()
    t += multiOutputTests()
    t += dsdOutputTests()
    t += creditGraphTests()
    t += performanceTests()
    t += midiTests()
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
    let rd = RadioTests()
    t += [("radio.demux", rd.icyDemuxerHandlesAnySplit), ("radio.fifo", rd.fifoIsBoundedAndOrdered), ("radio.http", rd.httpClientFollowsRedirectsAndDecodesChunks),
          ("radio.decode", rd.radioDecodesMetadataAndTone), ("radio.servers", rd.otherServerStyles), ("radio.failures", rd.failuresAreReportedQuickly),
          ("radio.reconnect", rd.reconnectsWhenTheServerDrops), ("radio.player", rd.playerPlaysAndUpscalesALiveStream), ("radio.flac", rd.losslessFLACStream), ("radio.settings", rd.radioSettingsDecodeFromOldSaves)]
    let dj = DJTests()
    t += [("dj.varispeedOne", dj.varispeedAtOneIsTransparent), ("dj.varispeedPitch", dj.varispeedChangesPitchAndLength), ("dj.varispeedLive", dj.varispeedLiveChangeAndSeek), ("dj.loops", dj.varispeedLoopsAndBends),
          ("dj.sharedRate", dj.decksResampleToTheSharedRate), ("dj.startPaused", dj.startingPausedPlaysNothingUntilToldTo), ("dj.gain", dj.deckGainScalesSmoothly),
          ("dj.pitch", dj.pitchControlThroughThePlayer), ("dj.eq", dj.deckEqCutsAndBoostsBands), ("dj.twoDecks", dj.twoDecksPlayAtTheSameTime),
          ("dj.crossfader", dj.crossfaderCurves), ("dj.maths", dj.eqProfileAndSync), ("dj.tempo", dj.tempoDetection), ("dj.waveform", dj.waveformOverview),
          ("dj.deck", dj.deckLifecycle), ("dj.mixing", dj.djModelMixing)]
    let djan = DJAnalysisTests()
    t += [("dj.camelot", djan.camelotWheel), ("dj.key", djan.keyDetection), ("dj.grid", djan.beatGridAndSections), ("dj.cache", djan.analysisCache)]
    let auto = AutoDJTests()
    t += [("net.quality", auto.netSeparatesGoodFromBadMixes), ("net.learn", auto.netLearnsFromFeedback), ("net.persist", auto.netPersists), ]
    let deckT = DJDeckTests()
    t += [("dj.hotcuesLoops", deckT.hotCuesAndLoops)]
    let coll = CollectionTests()
    t += [("lib.featuring", coll.featuringIsSplit), ("lib.composerSplit", coll.composersAreSplitCleanly), ("lib.guests", coll.guestsLiveUnderTheirHostArtist), ("lib.tidy", coll.existingLibrariesAreTidied), ("lib.collab", coll.collaborationsFoldIntoTheKnownArtist), ("lib.playlists", coll.likesAndPlaylists)]
    let dup = DuplicateTests()
    t += [("dup.titles", dup.titlesNormalise), ("dup.songs", dup.songDuplicates), ("dup.albums", dup.albumDuplicates), ("dup.remove", dup.removalFromTheLibrary)]
    let rep = RepeatTests()
    t += [("repeat.off", rep.repeatOffEnds), ("repeat.all", rep.repeatAllWrapsAround), ("repeat.one", rep.repeatOneStaysOnTheTrack), ("queue.order", rep.reorderingTheQueue)]
    let shf = ShuffleTests()
    t += [("shuffle.normal", shf.normalShuffleIsAPermutation), ("shuffle.smart", shf.smartShuffleSpreadsArtists), ("shuffle.liked", shf.smartShuffleKeepsTheCurrentSongFirstAndFavoursLiked), ("shuffle.flow", shf.smartShuffleUsesTheTransitionNetwork), ("shuffle.restore", shf.restoreOrder)]
    let dspm = DSPModelTests()
    t += [("dspm.profiles", dspm.profilesSaveAndComeBack), ("dspm.throttle", dspm.appliesAreThrottled), ("dspm.prompt", dspm.leavingTheDSPPageAsksFirst), ("dspm.master", dspm.turningOnTheEqualizerSwitchesTheDSPPathOn)]
    let rmx = RemixTests()
    t += [("remix.actions", rmx.performancesAreWellFormed), ("remix.context", rmx.contextComesFromTheTrack), ("remix.rules", rmx.policyKnowsTheRules), ("remix.learn", rmx.policyLearnsAndPersists), ("remix.controller", rmx.controllerPerformsAndRestores)]
    let diag = DiagnosticTests()
    t += [("diag.sorting", diag.sortingALargeLibraryIsFast), ("diag.queueWindow", diag.clickingASongQueuesAWindowNotTheLibrary), ("diag.rapidChanges", diag.changingSongsQuicklyNeverBlocks), ("diag.jumpBitPerfect", diag.theNewSongArrivesBitPerfectAfterAJump)]
    let lou = LoudnessTests()
    t += [("r128.filter", lou.filterMatchesTheReferenceBiquad), ("r128.integrated", lou.integratedLoudnessFollowsTheStandard), ("r128.gating", lou.gatingIgnoresQuietPassages), ("r128.lra", lou.loudnessRange), ("r128.truePeak", lou.truePeakSeesBetweenTheSamples), ("r128.dr", lou.dynamicRangeScore), ("r128.surround", lou.surroundChannelsAreWeighted), ("r128.files", lou.analysesFilesAndStaysFast), ("r128.cache", lou.theCacheKeepsAndForgets), ("r128.library", lou.theLibraryRemembersTheFigures), ("r128.leveling", lou.levelingEquallyLoudensDifferentMasters)]
    let mch = MultichannelTests()
    t += [("mch.layouts", mch.layoutsFollowTheFileFormats), ("mch.router", mch.channelsFindTheirSpeakers), ("mch.matrix", mch.downmixMathIsTheStandard), ("mch.direct", mch.surroundOnASurroundDeviceIsBitPerfect), ("mch.stereoDevice", mch.surroundOnAStereoDeviceIsMixedDown), ("mch.modes", mch.theModesDecide), ("mch.71", mch.sevenOneOnAFiveOneDevice), ("mch.switching", mch.switchingBetweenStereoAndSurround), ("mch.dsd", mch.dsdSurroundFallsBackToPCMOnAStereoDevice), ("mch.copy", mch.theOutputCopyHandlesEveryDeviceShape)]
    let xb = ExtremeBench()
    t += [("ext.bench", xb.bench), ("ext.fast", xb.benchFast), ("ext.rates", xb.ratesAreSupportedOrNot), ("ext.match", xb.cascadeMatchesTheSingleFilter), ("ext.reject", xb.cascadeRejectsWhatItShould), ("ext.seek", xb.seekingGivesTheSameSamples), ("ext.speed", xb.hugeRatesRunFasterThanRealTime), ("ext.six", xb.multichannelDSDWorksThroughTheCascade), ("ext.resample", xb.benchResampler), ("ext.profile", xb.theProfileDecidesWhatIsSustainable), ("ext.measure", xb.measuringIsQuickAndSane), ("ext.weakMachine", xb.upsamplingIsHeldBackOnAWeakMachine), ("ext.engine1024", xb.dsd1024PlaysThroughTheEngine), ("ext.1536", xb.megahertzPCMPassesThroughUnchanged), ("ext.8ch", xb.eightChannelsAtHighRates)]
    let rip = RipTests()
    let tc = TranscodeTests()
    let cl = CloudTests()
    let cs = CastTests()
    let sm = StreamingTests()
    let sdj = SmartDJTests()
    t += [("rip.ids", rip.discIdentifiersMatchTheDatabases), ("rip.enhanced", rip.enhancedDiscsLoseTheirDataTrack), ("rip.toc", rip.rawTOCParses), ("rip.checksums", rip.checksumsMatchAnIndependentImplementation), ("rip.database", rip.theDatabaseAnswerParsesAndVerifies), ("rip.musicbrainz", rip.musicBrainzKnowsTheDisc), ("rip.clean", rip.aCleanDiscRipsExactly), ("rip.offset", rip.theDrivesOffsetIsCorrected), ("rip.c2", rip.errorsThatTheDriveAdmitsAreRetried), ("rip.hidden", rip.errorsTheDriveHidesAreCaughtByRereading), ("rip.hopeless", rip.sectorsThatNeverSettleAreReportedNotHidden), ("rip.ioerrors", rip.readErrorsAreSurvivedOrReported), ("rip.cancel", rip.cancellingStopsTheRip), ("rip.files", rip.filesAreBitExactAndTagged), ("rip.log", rip.cueAndLogDescribeTheRip), ("rip.image", rip.aDiscImageRipsLikeADisc), ("rip.tagwriters", rip.tagWritersKeepTheAudioAndTheRestOfTheTags)]
    t += [("tc.gain", tc.gainMath), ("tc.aac", tc.aacLevelledWithTags), ("tc.peaks", tc.peaksStayUnderTheCeiling), ("tc.lossless", tc.losslessIsBitExact), ("tc.rates", tc.ratesAreConverted), ("tc.batch", tc.batchesRunInParallel), ("tc.failures", tc.failuresAndCancelling), ("tc.names", tc.namingAndFolders), ("tc.surround", tc.surroundBecomesStereo)]
    t += [("cloud.sigv4", cl.awsPublishedVectors), ("cloud.keys", cl.keysAreEncodedTheAwsWay), ("cloud.list", cl.listingsPageAndMapErrors), ("cloud.reader", cl.readerReturnsTheRightBytes), ("cloud.readahead", cl.readAheadHidesTheLatency), ("cloud.bitrate", cl.lookaheadFollowsTheBitrate), ("cloud.cache", cl.cacheStaysBounded), ("cloud.warm", cl.warmPreparesTheNextTrack), ("cloud.trouble", cl.networkTroubleIsRiddenOut), ("cloud.decode", cl.remoteFilesDecodeIdentically), ("cloud.import", cl.importingABucket), ("cloud.play", cl.cloudTracksPlayLikeFiles)]
    t += [("cast.flac", cs.flacEncoderIsLossless), ("cast.join", cs.joiningMidStream), ("cast.speed", cs.flacEncoderKeepsUpWithTheEngine), ("cast.codec", cs.castMessagesRoundTrip), ("cast.session", cs.castSessionStartsAndPlays), ("cast.trouble", cs.castTroubleIsReportedPlainly), ("cast.server", cs.streamServerServesLiveFrames), ("cast.player", cs.playerFeedsTheCastStream), ("cast.tls", cs.castOverRealTLS)]
    t += [("stream.client", sm.subsonicClientTalksToTheServer), ("stream.import", sm.importingAServer), ("stream.play", sm.serverTracksPlayLikeFiles)]
    t += [("smartdj.intent", sdj.requestsAreUnderstood), ("smartdj.rank", sdj.rankingFavoursWhatWasAsked), ("smartdj.context", sdj.contextIsSmallAndRelevant), ("smartdj.answers", sdj.answersAreCheckedAndRepaired), ("smartdj.pipeline", sdj.theWholePipeline), ("smartdj.service", sdj.modelLivesOnlyWhileSwitchedOn), ("smartdj.fallback", sdj.withoutAModelTheRankingStillAnswers), ("smartdj.process", sdj.theHelperProcessFollowsTheProtocol), ("smartdj.misbehave", sdj.theHelperProcessMisbehaves), ("smartdj.driver", sdj.theServiceDrivesTheHelperProcess), ("smartdj.real", sdj.theRealModelPicksTracks), ("smartdj.decks", sdj.aSetLandsOnTheDecks)]
    let it = IntelligenceTests()
    t += [("intelligence.hardware", it.hardwareIsDetected), ("intelligence.intel", it.intelIsOffByDefaultAndWarnsFirst), ("intelligence.intelUnavailable", it.intelShowsAppleSiliconOnlyFeaturesAsUnavailable), ("intelligence.helperArch", it.helperProgramsAreCheckedForTheirProcessorType), ("intelligence.killswitch", it.killswitchClosesEveryFeature),
          ("intelligence.gate", it.gateReadsAreAtomicWhilePublishing), ("intelligence.settings", it.settingsPersistAndKeysStayInTheKeychain), ("intelligence.models", it.modelsAreMeasuredAndCapped),
          ("intelligence.api", it.apiClientSpeaksOpenAICompatible), ("intelligence.smartdj", it.smartDJUsesTheChosenEngineAndObeysTheSwitch), ("intelligence.search", it.semanticSearchFindsSongsByMeaning)]
    let p5 = Phase5Tests()
    t += [("dither.stats", p5.ditherStatistics), ("dither.quiet", p5.ditherKeepsQuietSignals), ("dither.safety", p5.ditherSafety), ("dither.player", p5.ditherInThePlayer),
          ("zone.delay", p5.delayLineIsSampleExact), ("zone.balance", p5.balancerAndProbe), ("zone.feed", p5.feedDelaysTheStreamExactly), ("upnp.parse", p5.upnpDescriptionsAndSOAP),
          ("upnp.discovery", p5.discoveryByBroadcast), ("zone.start", p5.zoneStartsRoomsAndGroupsSonos), ("zone.refusal", p5.zoneSurvivesARoomThatRefuses), ("zone.align", p5.zoneAlignsRoomsThatLag),
          ("lms.client", p5.lmsClientAndPaths), ("lms.import", p5.lmsImportAndPlay), ("bridge.sync", p5.bridgePairingAndSync)]
    let ux = UXTests()
    t += [("ux.conflicts", ux.conflictRules), ("ux.sidebar", ux.sidebarLayout), ("ux.scroll", ux.scrollingNeverSticks), ("dj.layout", ux.djLayout), ("dj.tools", ux.djDeckTools), ("dj.assign", ux.djCrossfaderAssign), ("dj.knobs", ux.knobReadouts), ("ux.scrollGate", ux.scrollGate), ("speakers.volume", ux.speakerVolumeMatching), ("speakers.plan", ux.speakerPlan), ("speakers.roles", ux.speakerRoles), ("speakers.ring", ux.speakerDelayAndRing), ("speakers.devices", ux.speakersOnRealDevices)]
    let cal = CalibrationTests()
    t += [("calibration.roles", cal.roleBalance), ("calibration.curves", cal.volumeCurves), ("calibration.plan", cal.levelPlan), ("calibration.ramp", cal.hardwareRamp),
          ("calibration.gain", cal.smoothGain), ("calibration.threads", cal.smoothGainAcrossThreads), ("calibration.stage", cal.outputStage),
          ("calibration.follower", cal.followerSlides), ("calibration.clock", cal.followerRunsOnItsOwnClock), ("calibration.saves", cal.setupSaves),
          ("calibration.sender", cal.coalescingSender), ("calibration.zoneLevels", cal.zoneRoomLevels)]
    let mix = DJMixerTests()
    t += [("mixer.crossfade", mix.crossfaderGainsSelectTheDecks), ("mixer.masterEQ", mix.masterEqAndTrim), ("mixer.limiter", mix.limiterHoldsTheCeiling), ("mixer.cue", mix.cueBusCarriesOnlyTheCuedDeck),
          ("mixer.cueResampler", mix.cueResamplerFollowsAnotherClock), ("mixer.recorder", mix.recorderWritesAReadableWav)]
    let ai = ArtistImageTests()
    t += [("artist.deezer", ai.deezerParsing), ("artist.portrait", ai.portraitFromDeezerThenCache), ("artist.wikipedia", ai.wikipediaIsTheSecondChoice),
          ("artist.offline", ai.missingAndOfflineAreHandled), ("artist.mosaic", ai.mosaicLayouts)]
    let dt = DirectoryTests()
    t += [("directory.stations", dt.stationParsingKeepsOnlyPlayableStreams), ("directory.facets", dt.facetParsing), ("directory.queries", dt.radioQueriesAndFallbackServers),
          ("directory.favorites", dt.favoritesAndCustomStations), ("podcast.feed", dt.feedParsing), ("podcast.directory", dt.podcastDirectoryParsing),
          ("podcast.requests", dt.podcastRequestsAndLookups), ("podcast.download", dt.episodeDownloadsAreCachedAndVerified)]
    let hw = HardwareUITests()
    t += [("ui.ledContrast", hw.ledLegendsKeepContrast), ("ui.ledLamps", hw.lampsDescribeTheStream), ("ui.waveformBuild", hw.waveformFollowsTheAudio),
          ("ui.waveformCache", hw.waveformCacheRoundTrip), ("ui.waveformColumns", hw.waveformColumnsAndEdgeCases), ("ui.scrubMath", hw.scrubberMath),
          ("ui.backdropBlur", hw.backdropImageIsSmallAndBlurred), ("ui.stageNavigation", hw.stageOpensAndReturns), ("ui.lyricsButton", hw.lyricsButtonOpensTheLyrics)]
    let ds = DesignSystemTests()
    t += [("ui.themeContrast", ds.everyThemeMeetsContrast), ("ui.defaultThemes", ds.defaultThemesAreGraphiteAndStone), ("ui.typography", ds.typographyTokensArePresent),
          ("ui.noScatteredFonts", ds.noScatteredFontsOrSprings), ("ui.metrics", ds.metricsStayOnTheGridAndRound), ("ui.accentPair", ds.accentPairStaysInOneColourFamily),
          ("ui.softBackdrop", ds.softBackdropNeverCostsTextItsContrast), ("ui.albumBackdrop", ds.albumBackdropIsHeldToTheSameLimit), ("ui.backdropModes", ds.backdropModesAreNamed), ("ui.backdropView", ds.backdropViewDrawsTheWash)]
    let ui = InterfaceTests()
    t += [("ui.palette", ui.paletteFollowsTheCover), ("ui.paletteEdge", ui.greyAndTinyImagesAreSafe), ("ui.signalPath", ui.signalPathStations), ("ui.quality", ui.qualityTiers), ("ui.navigation", ui.navigationStructure), ("ui.liveSignal", ui.liveStationsInTheSignalPath), ("ui.history", ui.navigationHistory), ("ui.republish", ui.playheadChangesDoNotRepublish), ("ui.ordering", ui.sortingFilteringAndGrouping), ("ui.volumeSafety", ui.volumeSliderCannotJump), ("ui.scrollSteps", ui.scrollWheelSteps)]
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
    let tr = TransitionTests()
    t += [("transition.planner", tr.plannerRules), ("transition.settings", tr.settingsDecodeFromOldSaves), ("transition.edges", tr.edgeAnalysisFindsSilenceLoudnessAndFades),
          ("transition.mixerGuard", tr.mixerNeverClipsAndNeverSteps), ("transition.exact", tr.crossfadeIsExactOutsideTheOverlap), ("transition.status", tr.statusFollowsTheOverlap),
          ("transition.silence", tr.silenceIsTrimmed), ("transition.album", tr.albumsStayGapless), ("transition.formatChange", tr.formatChangeStaysGapless),
          ("transition.queueEdit", tr.removingTheNextTrackUndoesTheBufferedOverlap), ("transition.seek", tr.seekDuringTheOverlapStaysConsistent)]
    return t
}
