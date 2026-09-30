# Swift strict-concurrency survey — 2026-09-22

Measured on RicksM5 (macOS 27.0, Xcode 27.0 27A266a), detached worktree of origin/main 39956d86, Debug, clean builds, separate derivedData per run. No project files changed; the setting was passed on the xcodebuild command line (it also reached the VideoScanCore package).

Configurations: baseline = project as-is (SWIFT_VERSION 5.0, APPROACHABLE_CONCURRENCY YES, STRICT unset = minimal); targeted / complete = `SWIFT_STRICT_CONCURRENCY=<x>` override.

## Concurrency-warning counts (own code; third-party packages emitted none)

| Scope | baseline | targeted | complete |
|---|---|---|---|
| App target (`build`) | 81 | 110 (+29) | 195 (+114) |
| VideoScanCore | 0 | 0 | 18 (+18) |
| VideoScanTests (`build-for-testing`) | 37 | 101 (+64) | >=101, partial: compile stopped by 1 error, ~433/706 file compiles ran |
| VideoScanUITests | 0 | 0 | 55 (+55) |
| Errors | 0 | 0 | **1** (TestHostGateTests.swift:21, inside `#expect` macro expansion) |

All warnings, all targets: baseline 209, targeted 302, complete 365 (partial test coverage).

Clean app `build` times on M5: baseline 48 s, targeted 46 s, complete 45 s. build-for-testing times on the M5 were erratic (baseline 96 s to 1,049 s across identical reruns), so they are not reported as a comparison.

## Raw warnings — complete (app + VideoScanCore from `app-complete`; tests/UITests from `bft-complete`, partial)

### VideoScanUITests/Gauntlet/GauntletBase.swift (31)

- L57:14 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'terminate()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L70:60 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'screenshot()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L88:19 [B main-actor isolation from nonisolated] call to main actor-isolated initializer 'init()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L93:13 [B main-actor isolation from nonisolated] main actor-isolated property 'launchArguments' can not be mutated from a nonisolated context
- L94:13 [B main-actor isolation from nonisolated] main actor-isolated property 'launchEnvironment' can not be mutated from a nonisolated context
- L103:13 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'launch()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L114:23 [B main-actor isolation from nonisolated] main actor-isolated property 'buttons' can not be referenced from a nonisolated context
- L114:30 [B main-actor isolation from nonisolated] main actor-isolated subscript 'subscript(_:)' can not be referenced from a nonisolated context
- L115:27 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'waitForExistence(timeout:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L117:13 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'click()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L145:27 [B main-actor isolation from nonisolated] main actor-isolated property 'buttons' can not be referenced from a nonisolated context
- L145:34 [B main-actor isolation from nonisolated] main actor-isolated subscript 'subscript(_:)' can not be referenced from a nonisolated context
- L146:21 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'waitForExistence(timeout:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L147:31 [B main-actor isolation from nonisolated] main actor-isolated property 'buttons' can not be referenced from a nonisolated context
- L147:39 [B main-actor isolation from nonisolated] main actor-isolated property 'allElementsBoundByIndex' can not be referenced from a nonisolated context
- L148:27 [B main-actor isolation from nonisolated] main actor-isolated property 'identifier' can not be referenced from a nonisolated context
- L148:51 [B main-actor isolation from nonisolated] main actor-isolated property 'label' can not be referenced from a nonisolated context
- L148:62 [B main-actor isolation from nonisolated] main actor-isolated property 'identifier' can not be referenced from a nonisolated context
- L154:17 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'click()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L156:23 [B main-actor isolation from nonisolated] main actor-isolated property 'staticTexts' can not be referenced from a nonisolated context
- L156:34 [B main-actor isolation from nonisolated] main actor-isolated subscript 'subscript(_:)' can not be referenced from a nonisolated context
- L157:27 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'waitForExistence(timeout:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L167:24 [B main-actor isolation from nonisolated] main actor-isolated property 'menuItems' can not be referenced from a nonisolated context
- L167:34 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'matching' in a synchronous nonisolated context [#ActorIsolatedCall]
- L168:56 [B main-actor isolation from nonisolated] main actor-isolated property 'firstMatch' can not be referenced from a nonisolated context
- L169:28 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'waitForExistence(timeout:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L171:14 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'click()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L179:29 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'waitForExistence(timeout:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L181:15 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'click()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L182:15 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'typeKey(_:modifierFlags:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L183:15 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'typeText' in a synchronous nonisolated context [#ActorIsolatedCall]

### VideoScanUITests/CombineWorkflowUITests.swift (20)

- L176:19 [B main-actor isolation from nonisolated] call to main actor-isolated initializer 'init()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L181:13 [B main-actor isolation from nonisolated] main actor-isolated property 'launchArguments' can not be mutated from a nonisolated context
- L186:13 [B main-actor isolation from nonisolated] main actor-isolated property 'launchEnvironment' can not be mutated from a nonisolated context
- L188:13 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'launch()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L207:31 [B main-actor isolation from nonisolated] main actor-isolated property 'tables' can not be referenced from a nonisolated context
- L207:38 [B main-actor isolation from nonisolated] main actor-isolated property 'cells' can not be referenced from a nonisolated context
- L207:44 [D region isolation / sending] sending 'predicate' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]
- L207:44 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'matching' in a synchronous nonisolated context [#ActorIsolatedCall]
- L208:31 [B main-actor isolation from nonisolated] main actor-isolated property 'tables' can not be referenced from a nonisolated context
- L208:38 [B main-actor isolation from nonisolated] main actor-isolated property 'staticTexts' can not be referenced from a nonisolated context
- L208:50 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'matching' in a synchronous nonisolated context [#ActorIsolatedCall]
- L209:37 [B main-actor isolation from nonisolated] main actor-isolated property 'count' can not be referenced from a nonisolated context
- L210:37 [B main-actor isolation from nonisolated] main actor-isolated property 'count' can not be referenced from a nonisolated context
- L218:43 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'element(boundBy:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L223:47 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'element(boundBy:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L233:24 [B main-actor isolation from nonisolated] main actor-isolated property 'exists' can not be referenced from a nonisolated context
- L234:30 [B main-actor isolation from nonisolated] main actor-isolated property 'label' can not be referenced from a nonisolated context
- L236:18 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'rightClick()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L237:32 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'waitForExistence(timeout:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L241:17 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'typeKey(_:modifierFlags:)' in a synchronous nonisolated context [#ActorIsolatedCall]

### VideoScan/HallieBirthplaceTrail.swift (15)

- L63:24 [A global/static mutable state] static property 'trailMediaNoun' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L77:24 [A global/static mutable state] static property 'trailLineNoun' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L79:24 [A global/static mutable state] static property 'trailLinePhrase' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L92:24 [A global/static mutable state] static property 'trailBareLinePhrase' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L94:24 [A global/static mutable state] static property 'trailBirthCue' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L95:24 [A global/static mutable state] static property 'trailOriginCue' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L100:24 [A global/static mutable state] static property 'trailAncestryCue' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L101:24 [A global/static mutable state] static property 'trailOutsideUS' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L102:24 [A global/static mutable state] static property 'trailEurope' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L103:24 [A global/static mutable state] static property 'trailGenerationsAsk' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L104:24 [A global/static mutable state] static property 'trailGenerationCount' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L255:24 [A global/static mutable state] static property 'trailPossessiveWindow' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L258:24 [A global/static mutable state] static property 'trailDeterminerPhrase' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L260:24 [A global/static mutable state] static property 'trailAncestorsOf' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L319:24 [A global/static mutable state] static property 'trailSegment' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring /* ... repeated 10 times ... */)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScanCore/Sources/VideoScanCore/GedcomCompiledTree.swift (14)

- L184:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'checksumOK' in concurrently-executing code [#SendableClosureCaptures]
- L184:54 [C capture in @Sendable/concurrent closure] capture of 'payload' with non-Sendable type 'UnsafeRawBufferPointer' in a '@Sendable' closure [#SendableClosureCaptures]
- L226:22 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'buffer' is not allowed in concurrently-executing code [#SendableClosureCaptures]
- L226:22 [C capture in @Sendable/concurrent closure] capture of 'buffer' with non-Sendable type 'UnsafeMutableBufferPointer<String>' in a '@Sendable' closure [#SendableClosureCaptures]
- L227:79 [C capture in @Sendable/concurrent closure] capture of 'blob' with non-Sendable type 'UnsafeRawBufferPointer' in a '@Sendable' closure [#SendableClosureCaptures]
- L669:33 [C capture in @Sendable/concurrent closure] capture of 'template' with non-Sendable type 'GedcomCompiledTree.Reader' in a '@Sendable' closure [#SendableClosureCaptures]
- L670:36 [C capture in @Sendable/concurrent closure] reference to captured var 'starts' in concurrently-executing code [#SendableClosureCaptures]
- L671:35 [C capture in @Sendable/concurrent closure] reference to captured var 'starts' in concurrently-executing code [#SendableClosureCaptures]
- L676:63 [C capture in @Sendable/concurrent closure] capture of 'record' with non-Sendable type '(inout GedcomCompiledTree.Reader) throws -> T' in a '@Sendable' closure [#SendableClosureCaptures]
- L678:29 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'slotBuffer' is not allowed in concurrently-executing code [#SendableClosureCaptures]
- L678:29 [C capture in @Sendable/concurrent closure] capture of 'slotBuffer' with non-Sendable type 'UnsafeMutableBufferPointer<[T]>' in a '@Sendable' closure [#SendableClosureCaptures]
- L680:29 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'failureBuffer' is not allowed in concurrently-executing code [#SendableClosureCaptures]
- L680:29 [C capture in @Sendable/concurrent closure] capture of 'failureBuffer' with non-Sendable type 'UnsafeMutableBufferPointer<GedcomCompiledTree.CodecError?>' in a '@Sendable' closure [#SendableClosureCaptures]
- L682:29 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'failureBuffer' is not allowed in concurrently-executing code [#SendableClosureCaptures]

### VideoScan/ArcFacePredictor.swift (12)

- L26:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreML' [#AddPreconcurrencyImport]
- L30:16 [A global/static mutable state] static property 'shared' is not concurrency-safe because non-'Sendable' type 'ArcFacePredictor' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L40:49 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L51:30 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L51:45 [C capture in @Sendable/concurrent closure] implicit capture of 'self' requires that 'ArcFacePredictor' conforms to 'Sendable'; this is an error in the Swift 6 language mode
- L56:34 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L65:58 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to nonisolated context; this is an error in the Swift 6 language mode [#RegionIsolation]
- L72:13 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L72:21 [C capture in @Sendable/concurrent closure] capture of 'completedBuild' with non-Sendable type '[(model: MLModel, lock: OSAllocatedUnfairLock<Void>)]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L84:19 [E non-Sendable crossing isolation] type 'MLModel' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L85:20 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L85:56 [C capture in @Sendable/concurrent closure] capture of 'fallback' with non-Sendable type 'MLModel' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/OllamaQueryTranslator.swift (12)

- L855:16 [A global/static mutable state] static property 'responseSchema' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L882:16 [A global/static mutable state] static property 'astResponseSchema' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L911:24 [A global/static mutable state] static property 'astStringList' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L917:24 [A global/static mutable state] static property 'astYear' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L923:24 [A global/static mutable state] static property 'astMediaKind' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L928:24 [A global/static mutable state] static property 'astCatalogProperties' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L936:24 [A global/static mutable state] static property 'astCatalogPayload' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L942:24 [A global/static mutable state] static property 'astTextPayload' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L949:24 [A global/static mutable state] static property 'astTemporalPayload' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L980:24 [A global/static mutable state] static property 'astAggregatePayload' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L999:24 [A global/static mutable state] static property 'astGraphPayload' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L1013:24 [A global/static mutable state] static property 'astGraphFamilyTree' is not concurrency-safe because non-'Sendable' type '[String : Any]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScanTests/ProbeGroupAbortAccountingTests.swift (11)

- L27:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L63:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L63:24 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L85:28 [B main-actor isolation from nonisolated] non-Sendable type 'Task<(records: [VideoRecord], discovered: Int, completed: Int), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L85:37 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L85:37 [B main-actor isolation from nonisolated] non-Sendable type '(records: [VideoRecord], discovered: Int, completed: Int)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
- L186:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L186:24 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L202:28 [B main-actor isolation from nonisolated] non-Sendable type 'Task<(records: [VideoRecord], discovered: Int, completed: Int), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L202:37 [B main-actor isolation from nonisolated] non-Sendable type '(records: [VideoRecord], discovered: Int, completed: Int)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
- L202:37 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScan/ArcFaceEngine.swift (9)

- L6:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreML' [#AddPreconcurrencyImport]
- L190:17 [C capture in @Sendable/concurrent closure] capture of 'output' with non-Sendable type '(any MLFeatureProvider)?' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L190:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'output' in concurrently-executing code [#SendableClosureCaptures]
- L190:17 [C capture in @Sendable/concurrent closure] capture of 'output' with non-Sendable type '(any MLFeatureProvider)?' in an isolated closure
- L190:30 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L190:30 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in an isolated closure
- L190:53 [C capture in @Sendable/concurrent closure] capture of 'input' with non-Sendable type 'any MLFeatureProvider' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L190:53 [C capture in @Sendable/concurrent closure] capture of 'input' with non-Sendable type 'any MLFeatureProvider' in an isolated closure
- L192:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'swiftError' in concurrently-executing code [#SendableClosureCaptures]

### VideoScan/PersonFinderModel+JobLifecycle.swift (9)

- L35:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'Vision' [#AddPreconcurrencyImport]
- L299:35 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L299:35 [B main-actor isolation from nonisolated] non-Sendable type 'Task<([ReferenceFace], [ReferenceLoadFailure], String?), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L299:40 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L301:11 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L301:11 [B main-actor isolation from nonisolated] non-Sendable type '([ReferenceFace], [ReferenceLoadFailure], String?)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
- L894:23 [D region isolation / sending] passing closure as a 'sending' parameter risks causing data races between code in the current isolation context and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]
- L967:27 [D region isolation / sending] passing closure as a 'sending' parameter risks causing data races between code in the current isolation context and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]
- L1043:52 [C capture in @Sendable/concurrent closure] capture of 'prints' with non-Sendable type '[VNFeaturePrintObservation]' in a '@Sendable' local function; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/FamilyTreeLaunchBundle.swift (8)

- L64:37 [C capture in @Sendable/concurrent closure] capture of 'rowsOut' with non-Sendable type 'UnsafeMutablePointer<[FamilyTreePersonSummary]>' in a '@Sendable' closure [#SendableClosureCaptures]
- L66:37 [C capture in @Sendable/concurrent closure] capture of 'identityOut' with non-Sendable type 'UnsafeMutablePointer<FamilyAssetIdentityDirectory?>' in a '@Sendable' closure [#SendableClosureCaptures]
- L70:37 [C capture in @Sendable/concurrent closure] capture of 'anchorsOut' with non-Sendable type 'UnsafeMutablePointer<[FamilyTreeAnchor]>' in a '@Sendable' closure [#SendableClosureCaptures]
- L71:37 [C capture in @Sendable/concurrent closure] capture of 'captionOut' with non-Sendable type 'UnsafeMutablePointer<String?>' in a '@Sendable' closure [#SendableClosureCaptures]
- L76:45 [C capture in @Sendable/concurrent closure] capture of 'slots' with non-Sendable type 'UnsafeMutableBufferPointer<GedcomFamilyGraph.AncestorIndex?>' in a '@Sendable' closure [#SendableClosureCaptures]
- L76:45 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'slots' is not allowed in concurrently-executing code [#SendableClosureCaptures]
- L79:37 [C capture in @Sendable/concurrent closure] capture of 'indexesOut' with non-Sendable type 'UnsafeMutablePointer<[String : GedcomFamilyGraph.AncestorIndex]>' in a '@Sendable' closure [#SendableClosureCaptures]
- L135:14 [D region isolation / sending] passing closure as a 'sending' parameter risks causing data races between code in the current isolation context and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]

### VideoScan/HallieTreeStatisticsQuestion.swift (8)

- L39:24 [A global/static mutable state] static property 'countAsk' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring?)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L40:24 [A global/static mutable state] static property 'averageAsk' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L41:24 [A global/static mutable state] static property 'lifespanWord' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L42:24 [A global/static mutable state] static property 'groupingAsk' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring?, Substring?, Substring?)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L44:24 [A global/static mutable state] static property 'populationWord' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L45:24 [A global/static mutable state] static property 'ancestorScope' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L48:24 [A global/static mutable state] static property 'sidedScope' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L54:24 [A global/static mutable state] static property 'unsupportedConstraint' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring?, Substring?)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/PersonEvaluationCLI.swift (8)

- L152:32 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L152:32 [B main-actor isolation from nonisolated] non-Sendable type 'Task<([ReferenceFace], [ReferenceLoadFailure], String?), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L152:37 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L154:15 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L154:15 [B main-actor isolation from nonisolated] non-Sendable type '([ReferenceFace], [ReferenceLoadFailure], String?)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
- L174:50 [C capture in @Sendable/concurrent closure] capture of 'faces' with non-Sendable type '[ReferenceFace]' in a '@Sendable' local function; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L183:71 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to nonisolated context; this is an error in the Swift 6 language mode [#RegionIsolation]
- L203:71 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to nonisolated context; this is an error in the Swift 6 language mode [#RegionIsolation]

### VideoScan/HallieWebServer.swift (7)

- L227:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'failure' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L252:14 [C capture in @Sendable/concurrent closure] concurrently-executed local function 'receive()' must be marked as '@Sendable'
- L255:31 [C capture in @Sendable/concurrent closure] mutation of captured var 'buffer' in concurrently-executing code [#SendableClosureCaptures]
- L256:48 [C capture in @Sendable/concurrent closure] reference to captured var 'buffer' in concurrently-executing code [#SendableClosureCaptures]
- L258:82 [C capture in @Sendable/concurrent closure] capture of 'receive()' with non-Sendable type '() -> ()' in a '@Sendable' closure [#SendableClosureCaptures]
- L297:14 [C capture in @Sendable/concurrent closure] concurrently-executed local function 'next()' must be marked as '@Sendable'
- L310:89 [C capture in @Sendable/concurrent closure] capture of 'next()' with non-Sendable type '() -> ()' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/FamilyTreeLiveModel.swift (6)

- L750:33 [B main-actor isolation from nonisolated] passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]
- L885:35 [B main-actor isolation from nonisolated] passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]
- L952:22 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'buffer' is not allowed in concurrently-executing code [#SendableClosureCaptures]
- L952:22 [C capture in @Sendable/concurrent closure] capture of 'buffer' with non-Sendable type 'UnsafeMutableBufferPointer<FamilyTreePersonSummary>' in a '@Sendable' closure [#SendableClosureCaptures]
- L2032:35 [B main-actor isolation from nonisolated] passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]
- L2067:37 [B main-actor isolation from nonisolated] passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]

### VideoScan/HallieLineageQuestion.swift (6)

- L531:16 [A global/static mutable state] static property 'interrogativeFetchClause' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L537:16 [A global/static mutable state] static property 'clauseSeam' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L1041:16 [A global/static mutable state] static property 'mediaNoun' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L1058:24 [A global/static mutable state] static property 'superlativeWords' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L1160:24 [A global/static mutable state] static property 'kinshipApposition' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L1249:16 [A global/static mutable state] static property 'yearBoundPhrase' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/MediaStreamResolver.swift (6)

- L136:64 [B main-actor isolation from nonisolated] main actor-isolated static property 'portKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L136:100 [B main-actor isolation from nonisolated] main actor-isolated static property 'defaultPort' can not be referenced from a nonisolated autoclosure; this is an error in the Swift 6 language mode
- L138:92 [B main-actor isolation from nonisolated] main actor-isolated static property 'defaultPort' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L139:86 [B main-actor isolation from nonisolated] main actor-isolated static property 'passphraseKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L288:28 [B main-actor isolation from nonisolated] main actor-isolated static property 'browserPlayableExtensions' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L289:48 [B main-actor isolation from nonisolated] main actor-isolated static property 'nativeMovCodecs' can not be referenced from a nonisolated autoclosure; this is an error in the Swift 6 language mode

### VideoScanTests/GeneratedMediaPerformanceTests.swift (6)

- L4:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L207:15 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L207:51 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L211:23 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L220:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L224:27 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScanTests/ProbeGroupBoundedChildrenTests.swift (6)

- L30:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L233:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L233:24 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L249:18 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L250:28 [B main-actor isolation from nonisolated] non-Sendable type 'Task<(records: [VideoRecord], discovered: Int, completed: Int), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L250:37 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScan/PersonFinderModel.swift (5)

- L517:47 [B main-actor isolation from nonisolated] non-Sendable type 'Task<([ReferenceFace], [ReferenceLoadFailure], String?), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L517:47 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L517:52 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L519:11 [E non-Sendable crossing isolation] type 'ReferenceFace' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L519:11 [B main-actor isolation from nonisolated] non-Sendable type '([ReferenceFace], [ReferenceLoadFailure], String?)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode

### VideoScan/VideoScanModel+LiveReload.swift (5)

- L87:46 [B main-actor isolation from nonisolated] non-Sendable type 'Task<[VideoRecord]?, Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L87:46 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L87:51 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L89:11 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L89:11 [B main-actor isolation from nonisolated] non-Sendable type '[VideoRecord]?' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode

### VideoScanTests/StressTests.swift (5)

- L6:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L300:15 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L300:51 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L302:23 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L309:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScan/FamilyAssetIdentityDirectory.swift (4)

- L146:14 [C capture in @Sendable/concurrent closure] concurrently-executed local function 'nicknameTokens' must be marked as '@Sendable'
- L159:32 [C capture in @Sendable/concurrent closure] capture of 'nicknameTokens' with non-Sendable type '([String]) -> Set<String>' in a '@Sendable' closure [#SendableClosureCaptures]
- L162:22 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'buffer' is not allowed in concurrently-executing code [#SendableClosureCaptures]
- L162:22 [C capture in @Sendable/concurrent closure] capture of 'buffer' with non-Sendable type 'UnsafeMutableBufferPointer<FamilyAssetIdentityDirectory.Member>' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/ThumbnailPrecache.swift (4)

- L239:49 [C capture in @Sendable/concurrent closure] reference to captured var 'model' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L289:45 [C capture in @Sendable/concurrent closure] reference to captured var 'model' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L309:27 [D region isolation / sending] passing closure as a 'sending' parameter risks causing data races between code in the current isolation context and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]
- L329:31 [D region isolation / sending] passing closure as a 'sending' parameter risks causing data races between code in the current isolation context and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]

### VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift (4)

- L951:26 [C capture in @Sendable/concurrent closure] capture of 'f' with non-Sendable type 'ISO8601DateFormatter' in a '@Sendable' closure [#SendableClosureCaptures]
- L966:27 [C capture in @Sendable/concurrent closure] capture of 'withFraction' with non-Sendable type 'ISO8601DateFormatter' in a '@Sendable' closure [#SendableClosureCaptures]
- L966:60 [C capture in @Sendable/concurrent closure] implicit capture of 'plain' requires that 'ISO8601DateFormatter' conforms to 'Sendable'
- L966:60 [C capture in @Sendable/concurrent closure] capture of 'plain' with non-Sendable type 'ISO8601DateFormatter' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScanTests/RelocateSheetBrowseTests.swift (4)

- L25:31 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'derivedDestination(chosen:sourcePath:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L31:31 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'derivedDestination(chosen:sourcePath:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L37:31 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'derivedDestination(chosen:sourcePath:)' in a synchronous nonisolated context [#ActorIsolatedCall]
- L43:31 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'derivedDestination(chosen:sourcePath:)' in a synchronous nonisolated context [#ActorIsolatedCall]

### VideoScanUITests/CombineBulkWorkflowUITests.swift (4)

- L147:19 [B main-actor isolation from nonisolated] call to main actor-isolated initializer 'init()' in a synchronous nonisolated context [#ActorIsolatedCall]
- L148:13 [B main-actor isolation from nonisolated] main actor-isolated property 'launchArguments' can not be mutated from a nonisolated context
- L154:13 [B main-actor isolation from nonisolated] main actor-isolated property 'launchEnvironment' can not be mutated from a nonisolated context
- L158:13 [B main-actor isolation from nonisolated] call to main actor-isolated instance method 'launch()' in a synchronous nonisolated context [#ActorIsolatedCall]

### VideoScan/CaptionRunner.swift (3)

- L10:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'MLXLMCommon' [#AddPreconcurrencyImport]
- L573:61 [C capture in @Sendable/concurrent closure] capture of 'chat' with non-Sendable type '[Chat.Message]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L687:61 [C capture in @Sendable/concurrent closure] capture of 'chat' with non-Sendable type '[Chat.Message]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/HallieKinshipApposition.swift (3)

- L63:16 [A global/static mutable state] static property 'biographyTail' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L65:24 [A global/static mutable state] static property 'kinWord' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L80:24 [A global/static mutable state] static property 'shape' is not concurrency-safe because non-'Sendable' type 'Regex<(Substring, Substring, Substring?, Substring, Substring)>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/HallieShellCLI.swift (3)

- L1295:26 [D region isolation / sending] sending 'state.records' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]
- L1300:26 [D region isolation / sending] sending 'state.records' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]
- L1802:41 [D region isolation / sending] sending 'resolution' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]

### VideoScan/HallieSpeaker.swift (3)

- L416:64 [E non-Sendable crossing isolation] converting non-Sendable function value to '@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void' may introduce data races
- L420:62 [E non-Sendable crossing isolation] converting non-Sendable function value to '@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void' may introduce data races
- L575:29 [D region isolation / sending] sending 'synthesizer' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]

### VideoScan/NativeRecipeScorer.swift (3)

- L160:75 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to actor-isolated context; this is an error in the Swift 6 language mode [#RegionIsolation]
- L161:75 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to actor-isolated context; this is an error in the Swift 6 language mode [#RegionIsolation]
- L181:69 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to actor-isolated context; this is an error in the Swift 6 language mode [#RegionIsolation]

### VideoScan/POIStorage.swift (3)

- L533:24 [A global/static mutable state] static property 'migrationStates' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L559:24 [A global/static mutable state] static property 'pendingCatalogLogLines' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L571:24 [A global/static mutable state] static property 'reportedSkips' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/RAMAssetLoader.swift (3)

- L202:16 [A global/static mutable state] static property 'isEnabled' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L203:16 [A global/static mutable state] static property 'maxFileSizeBytes' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L204:16 [A global/static mutable state] static property 'budgetBytes' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/VideoScanModel.swift (3)

- L851:5 [E non-Sendable crossing isolation] 'nonisolated' can not be applied to variable with non-'Sendable' type 'MetadataCache'; this is an error in the Swift 6 language mode
- L1203:35 [D region isolation / sending] sending 'note' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]
- L1573:30 [E non-Sendable crossing isolation] non-Sendable type 'MetadataCache' of property 'metadataCache' cannot exit nonisolated context; this is an error in the Swift 6 language mode [#NonSendableExitingActor]

### VideoScan/ArchiveAngelAttention.swift (2)

- L258:37 [B main-actor isolation from nonisolated] main actor-isolated static property 'attentionKinds' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L267:31 [B main-actor isolation from nonisolated] main actor-isolated static property 'attentionKinds' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/FamilySearchPullCenter.swift (2)

- L16:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'UserNotifications' [#AddPreconcurrencyImport]
- L169:13 [C capture in @Sendable/concurrent closure] capture of 'center' with non-Sendable type 'UNUserNotificationCenter' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/FamilySearchPullCoordinator.swift (2)

- L421:33 [B main-actor isolation from nonisolated] passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]
- L679:33 [B main-actor isolation from nonisolated] passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]

### VideoScan/FindPersonJob.swift (2)

- L567:27 [D region isolation / sending] sending 'byPath' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]
- L567:56 [C capture in @Sendable/concurrent closure] capture of 'byPath' with non-Sendable type '[String : VideoRecord]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/FramePrefetcher.swift (2)

- L79:23 [C capture in @Sendable/concurrent closure] capture of 'assetReader' with non-Sendable type 'AVAssetReader' in a '@Sendable' closure [#SendableClosureCaptures]
- L93:46 [C capture in @Sendable/concurrent closure] capture of 'output' with non-Sendable type 'AVAssetReaderTrackOutput' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/HallieWebBridge.swift (2)

- L833:51 [B main-actor isolation from nonisolated] main actor-isolated static property 'maxDocumentBytes' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L835:29 [B main-actor isolation from nonisolated] main actor-isolated static property 'maxDocumentBytes' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/IdentifyFamilyModel.swift (2)

- L244:45 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L247:45 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/MasterArchiveIcon.swift (2)

- L24:20 [B main-actor isolation from nonisolated] main actor-isolated var 'NSApp' can not be referenced from a nonisolated context
- L24:27 [B main-actor isolation from nonisolated] main actor-isolated property 'applicationIconImage' can not be referenced from a nonisolated context

### VideoScan/MediaFileOperationsWindow.swift (2)

- L42:49 [B main-actor isolation from nonisolated] main actor-isolated static property 'sceneID' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L43:30 [B main-actor isolation from nonisolated] main actor-isolated static property 'title' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/PersonFinderCache.swift (2)

- L25:16 [A global/static mutable state] static property 'shared' is not concurrency-safe because non-'Sendable' type 'PersonFinderCache' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L199:24 [A global/static mutable state] static property 'refHashCache' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/PersonFinderEngineDispatch.swift (2)

- L77:58 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to nonisolated context; this is an error in the Swift 6 language mode [#RegionIsolation]
- L155:58 [D region isolation / sending] non-Sendable '(MLModel?, String?)'-typed result can not be returned from actor-isolated instance method 'getModel()' to nonisolated context; this is an error in the Swift 6 language mode [#RegionIsolation]

### VideoScan/PersonFinderTypes.swift (2)

- L271:24 [A global/static mutable state] static property 'defaults' is not concurrency-safe because non-'Sendable' type 'UserDefaults' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]
- L1296:24 [A global/static mutable state] static property 'defaults' is not concurrency-safe because non-'Sendable' type 'UserDefaults' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/VideoScanModel+ProbeEngine.swift (2)

- L791:25 [E non-Sendable crossing isolation] non-Sendable type 'MetadataCache' of property 'metadataCache' cannot exit nonisolated context; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L904:13 [E non-Sendable crossing isolation] non-Sendable type 'MetadataCache' of property 'metadataCache' cannot exit nonisolated context; this is an error in the Swift 6 language mode [#NonSendableExitingActor]

### VideoScan/VideoScanModel+RelocateQueue.swift (2)

- L2:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'UserNotifications' [#AddPreconcurrencyImport]
- L283:13 [C capture in @Sendable/concurrent closure] capture of 'center' with non-Sendable type 'UNUserNotificationCenter' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScanTests/ArchivistRecordExecutorTests.swift (2)

- L3:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L192:6 [E non-Sendable crossing isolation] type 'StreamType' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScanTests/HallieModeClassifierTests.swift (2)

- L11:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScan' [#AddPreconcurrencyImport]
- L23:24 [A global/static mutable state] static property 'oracle' is not concurrency-safe because non-'Sendable' type 'HallieModeClassifierTests.C.Oracle' (aka 'HallieModeClassifier.Oracle') may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScanTests/MediaStreamResolverTests.swift (2)

- L268:56 [B main-actor isolation from nonisolated] main actor-isolated class property 'passphraseKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L269:53 [B main-actor isolation from nonisolated] main actor-isolated class property 'portKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScanTests/RemoteViewerIsolationTests.swift (2)

- L71:53 [B main-actor isolation from nonisolated] main actor-isolated class property 'portKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L72:42 [B main-actor isolation from nonisolated] main actor-isolated class property 'passphraseKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/ArchiveAngelEvidenceStore.swift (1)

- L168:74 [B main-actor isolation from nonisolated] main actor-isolated static property 'filename' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/CatalogWriteError.swift (1)

- L180:16 [A global/static mutable state] static property 'maxBytes' is not concurrency-safe because it is nonisolated global shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/DeleteDuplicatesJob.swift (1)

- L695:28 [B main-actor isolation from nonisolated] main actor-isolated static property 'slotCapacity' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/DuplicateDetector.swift (1)

- L460:24 [A global/static mutable state] static property 'scoringRules' is not concurrency-safe because non-'Sendable' type '[DuplicateDetector.ScoringRule]' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/FamilyKinshipOverlay.swift (1)

- L389:43 [B main-actor isolation from nonisolated] converting function value of type '@MainActor @Sendable (POIProfile) -> ArchivistGraphProfileSnapshot' to '(POIProfile) -> ArchivistGraphProfileSnapshot' loses global actor 'MainActor'; this is an error in the Swift 6 language mode

### VideoScan/FamilyTreeRecompileCenter.swift (1)

- L104:35 [B main-actor isolation from nonisolated] passing closure as a 'sending' parameter risks causing data races between main actor-isolated code and concurrent execution of the closure; this is an error in the Swift 6 language mode [#RegionIsolation::SendingClosureRisksDataRace]

### VideoScan/HallieModeClassifier.swift (1)

- L35:20 [A global/static mutable state] static property 'none' is not concurrency-safe because non-'Sendable' type 'HallieModeClassifier.Oracle' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/HalliePropertyAsk.swift (1)

- L30:24 [A global/static mutable state] static property 'pattern' is not concurrency-safe because non-'Sendable' type 'Regex<AnyRegexOutput>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/HallieRepairTurn.swift (1)

- L76:24 [A global/static mutable state] static property 'centuryDecade' is not concurrency-safe because non-'Sendable' type 'Regex<Substring>' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/HallieTurnExecutor+Relationship.swift (1)

- L317:36 [C capture in @Sendable/concurrent closure] reference to captured var 'subjects' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/HelperAudioRepair.swift (1)

- L312:43 [E non-Sendable crossing isolation] passing non-Sendable parameter 'onChange' to function expecting a '@Sendable' closure

### VideoScan/MLXSafety.swift (1)

- L143:15 [D region isolation / sending] sending value of non-Sendable type '@concurrent () async throws -> R' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]

### VideoScan/MasterArchive.swift (1)

- L843:24 [A global/static mutable state] static property 'iso8601' is not concurrency-safe because non-'Sendable' type 'ISO8601DateFormatter' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScan/MemoryPressure.swift (1)

- L40:31 [A global/static mutable state] reference to var 'vm_kernel_page_size' is not concurrency-safe because it involves shared mutable state; this is an error in the Swift 6 language mode

### VideoScan/PersonEditSheet.swift (1)

- L386:35 [B main-actor isolation from nonisolated] main actor-isolated property 'isImporting' can not be referenced from a Sendable closure

### VideoScan/PersonFinderCompilation.swift (1)

- L90:67 [C capture in @Sendable/concurrent closure] capture of 'session' with non-Sendable type 'AVAssetExportSession' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/VerifyAudioSheet.swift (1)

- L63:17 [D region isolation / sending] sending 'action' risks causing data races; this is an error in the Swift 6 language mode [#RegionIsolation::SendingRisksDataRace]

### VideoScan/VideoScanModel+DateInference.swift (1)

- L877:30 [B main-actor isolation from nonisolated] main actor-isolated static property 'folderYearPriorRange' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/VideoScanModel+Filmstrip.swift (1)

- L306:49 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/ArchiveAngelLoggingAndOrderTests.swift (1)

- L53:22 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'mergedNotes(existing:adding:)' in a synchronous nonisolated context [#ActorIsolatedCall]

### VideoScanTests/CatalogSizeTotalsTests.swift (1)

- L56:13 [A global/static mutable state] let 'never' is not concurrency-safe because non-'Sendable' type '(VideoRecord) -> Bool' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

### VideoScanTests/HallieModelReadinessTests.swift (1)

- L121:50 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'probeWord' in a synchronous nonisolated context [#ActorIsolatedCall]

### VideoScanTests/SignatureConcurrencyScaleTests.swift (1)

- L29:13 [A global/static mutable state] let 'volumeOfPath' is not concurrency-safe because non-'Sendable' type '(String) -> String' may have shared mutable state; this is an error in the Swift 6 language mode [#MutableGlobalVariable]

## Raw warnings — targeted, NEW vs baseline (full coverage, all targets)

### VideoScanTests/StressTests/ArcFaceMLE5ProvocationTests.swift (16)

- L74:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L75:32 [C capture in @Sendable/concurrent closure] reference to captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L89:59 [C capture in @Sendable/concurrent closure] capture of 'pb' with non-Sendable type 'CVPixelBuffer' (aka 'CVBuffer') in an isolated closure
- L92:38 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in an isolated closure
- L181:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L182:32 [C capture in @Sendable/concurrent closure] reference to captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L194:59 [C capture in @Sendable/concurrent closure] capture of 'pb' with non-Sendable type 'CVPixelBuffer' (aka 'CVBuffer') in an isolated closure
- L197:38 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in an isolated closure
- L263:63 [C capture in @Sendable/concurrent closure] capture of 'pb' with non-Sendable type 'CVPixelBuffer' (aka 'CVBuffer') in an isolated closure
- L266:42 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in an isolated closure
- L353:21 [C capture in @Sendable/concurrent closure] mutation of captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L354:36 [C capture in @Sendable/concurrent closure] reference to captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L452:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L453:32 [C capture in @Sendable/concurrent closure] reference to captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L464:34 [C capture in @Sendable/concurrent closure] capture of 'pixelBuffers' with non-Sendable type '[CVPixelBuffer]' (aka 'Array<CVBuffer>') in an isolated closure
- L471:38 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in an isolated closure

### VideoScanTests/ProbeGroupAbortAccountingTests.swift (11)

- L27:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L63:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L63:24 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L85:28 [B main-actor isolation from nonisolated] non-Sendable type 'Task<(records: [VideoRecord], discovered: Int, completed: Int), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L85:37 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L85:37 [B main-actor isolation from nonisolated] non-Sendable type '(records: [VideoRecord], discovered: Int, completed: Int)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
- L186:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L186:24 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L202:28 [B main-actor isolation from nonisolated] non-Sendable type 'Task<(records: [VideoRecord], discovered: Int, completed: Int), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L202:37 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L202:37 [B main-actor isolation from nonisolated] non-Sendable type '(records: [VideoRecord], discovered: Int, completed: Int)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode

### VideoScanTests/ProbeGroupBoundedChildrenTests.swift (7)

- L30:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L233:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L233:24 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L249:18 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L250:28 [B main-actor isolation from nonisolated] non-Sendable type 'Task<(records: [VideoRecord], discovered: Int, completed: Int), Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L250:37 [B main-actor isolation from nonisolated] non-Sendable type '(records: [VideoRecord], discovered: Int, completed: Int)' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode
- L250:37 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScan/ArcFacePredictor.swift (6)

- L26:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreML' [#AddPreconcurrencyImport]
- L51:30 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L51:45 [C capture in @Sendable/concurrent closure] implicit capture of 'self' requires that 'ArcFacePredictor' conforms to 'Sendable'; this is an error in the Swift 6 language mode
- L56:34 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L72:13 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'ArcFacePredictor' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L72:21 [C capture in @Sendable/concurrent closure] capture of 'completedBuild' with non-Sendable type '[(model: MLModel, lock: OSAllocatedUnfairLock<Void>)]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/GeneratedMediaPerformanceTests.swift (6)

- L4:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L207:15 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L207:51 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L211:23 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L220:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L224:27 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScan/VideoScanModel+LiveReload.swift (5)

- L87:46 [B main-actor isolation from nonisolated] non-Sendable type 'Task<[VideoRecord]?, Never>' cannot exit main actor-isolated context in call to nonisolated property 'value'; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L87:46 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L87:51 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L89:11 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L89:11 [B main-actor isolation from nonisolated] non-Sendable type '[VideoRecord]?' of nonisolated property 'value' cannot be sent to main actor-isolated context; this is an error in the Swift 6 language mode

### VideoScanTests/StressTests.swift (5)

- L6:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L300:15 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L300:51 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L302:23 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode
- L309:13 [E non-Sendable crossing isolation] type 'VideoRecord' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScanTests/ArcFaceMLE5CrashTests.swift (4)

- L187:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L188:32 [C capture in @Sendable/concurrent closure] reference to captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L231:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L232:32 [C capture in @Sendable/concurrent closure] reference to captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]

### VideoScan/CaptionRunner.swift (3)

- L10:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'MLXLMCommon' [#AddPreconcurrencyImport]
- L573:61 [C capture in @Sendable/concurrent closure] capture of 'chat' with non-Sendable type '[Chat.Message]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L687:61 [C capture in @Sendable/concurrent closure] capture of 'chat' with non-Sendable type '[Chat.Message]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/FamilySearchPullMergeTests.swift (3)

- L12:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L148:39 [C capture in @Sendable/concurrent closure] capture of 'store' with non-Sendable type 'FamilyGraphCompiledStore' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L180:39 [C capture in @Sendable/concurrent closure] capture of 'store' with non-Sendable type 'FamilyGraphCompiledStore' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/ArcFaceEngine.swift (2)

- L190:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'output' in concurrently-executing code [#SendableClosureCaptures]
- L192:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'swiftError' in concurrently-executing code [#SendableClosureCaptures]

### VideoScan/FamilyTreeLaunchBundle.swift (2)

- L76:45 [C capture in @Sendable/concurrent closure] capture of 'slots' with non-Sendable type 'UnsafeMutableBufferPointer<GedcomFamilyGraph.AncestorIndex?>' in a '@Sendable' closure [#SendableClosureCaptures]
- L76:45 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'slots' is not allowed in concurrently-executing code [#SendableClosureCaptures]

### VideoScan/PersonFinderModel+JobLifecycle.swift (2)

- L35:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'Vision' [#AddPreconcurrencyImport]
- L1043:52 [C capture in @Sendable/concurrent closure] capture of 'prints' with non-Sendable type '[VNFeaturePrintObservation]' in a '@Sendable' local function; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VideoScanModel+Combine.swift (2)

- L199:40 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code [#SendableClosureCaptures]
- L204:27 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code [#SendableClosureCaptures]

### VideoScan/VideoScanModel+ProbeEngine.swift (2)

- L791:25 [E non-Sendable crossing isolation] non-Sendable type 'MetadataCache' of property 'metadataCache' cannot exit nonisolated context; this is an error in the Swift 6 language mode [#NonSendableExitingActor]
- L904:13 [E non-Sendable crossing isolation] non-Sendable type 'MetadataCache' of property 'metadataCache' cannot exit nonisolated context; this is an error in the Swift 6 language mode [#NonSendableExitingActor]

### VideoScan/VideoScanModel.swift (2)

- L851:5 [E non-Sendable crossing isolation] 'nonisolated' can not be applied to variable with non-'Sendable' type 'MetadataCache'; this is an error in the Swift 6 language mode
- L1573:30 [E non-Sendable crossing isolation] non-Sendable type 'MetadataCache' of property 'metadataCache' cannot exit nonisolated context; this is an error in the Swift 6 language mode [#NonSendableExitingActor]

### VideoScanTests/ArcFaceModelLoaderTests.swift (2)

- L119:17 [C capture in @Sendable/concurrent closure] mutation of captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]
- L120:32 [C capture in @Sendable/concurrent closure] reference to captured var 'readyCount' in concurrently-executing code [#SendableClosureCaptures]

### VideoScanTests/DeleteDuplicatesSiblingProofTests.swift (2)

- L30:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L412:6 [E non-Sendable crossing isolation] type 'VolumeMediaTech' does not conform to the 'Sendable' protocol; this is an error in the Swift 6 language mode

### VideoScanTests/FamilyGraphCompiledStoreTests.swift (2)

- L12:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L659:113 [C capture in @Sendable/concurrent closure] capture of 'store' with non-Sendable type 'FamilyGraphCompiledStore' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/HallieQueryBench.swift (2)

- L37:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L614:79 [C capture in @Sendable/concurrent closure] capture of 'records' with non-Sendable type '[VideoRecord]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/FamilyTreeLiveModel.swift (1)

- L952:22 [C capture in @Sendable/concurrent closure] mutable capture of 'inout' parameter 'buffer' is not allowed in concurrently-executing code [#SendableClosureCaptures]

### VideoScan/FindPersonJob.swift (1)

- L567:56 [C capture in @Sendable/concurrent closure] capture of 'byPath' with non-Sendable type '[String : VideoRecord]' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VerifyAudioSheet.swift (1)

- L63:17 [C capture in @Sendable/concurrent closure] capture of 'action' with non-Sendable type '() -> Void' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScanTests/ArchivistRecordExecutorTests.swift (1)

- L3:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]

### VideoScanTests/BackupAttestationJournalTests.swift (1)

- L106:54 [C capture in @Sendable/concurrent closure] mutation of captured var 'seen' in concurrently-executing code [#SendableClosureCaptures]

### VideoScanTests/BackupAttestationSensorTests.swift (1)

- L210:54 [C capture in @Sendable/concurrent closure] mutation of captured var 'seen' in concurrently-executing code [#SendableClosureCaptures]

### VideoScanTests/HallieShellCLITests.swift (1)

- L93:21 [C capture in @Sendable/concurrent closure] capture of 'self' with non-Sendable type 'HallieShellCLITests.Harness' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

## Baseline (minimal) concurrency warnings already present today

### VideoScanTests/StressTests/ArcFaceMLE5ProvocationTests.swift (10)

- L2:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreML' [#AddPreconcurrencyImport]
- L89:59 [C capture in @Sendable/concurrent closure] capture of 'pb' with non-Sendable type 'CVPixelBuffer' (aka 'CVBuffer') in a '@Sendable' closure [#SendableClosureCaptures]
- L92:38 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]
- L194:59 [C capture in @Sendable/concurrent closure] capture of 'pb' with non-Sendable type 'CVPixelBuffer' (aka 'CVBuffer') in a '@Sendable' closure [#SendableClosureCaptures]
- L197:38 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]
- L263:63 [C capture in @Sendable/concurrent closure] capture of 'pb' with non-Sendable type 'CVPixelBuffer' (aka 'CVBuffer') in a '@Sendable' closure [#SendableClosureCaptures]
- L266:42 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]
- L369:32 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]
- L464:34 [C capture in @Sendable/concurrent closure] capture of 'pixelBuffers' with non-Sendable type '[CVPixelBuffer]' (aka 'Array<CVBuffer>') in a '@Sendable' closure [#SendableClosureCaptures]
- L471:38 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/MediaStreamResolver.swift (6)

- L136:64 [B main-actor isolation from nonisolated] main actor-isolated static property 'portKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L136:100 [B main-actor isolation from nonisolated] main actor-isolated static property 'defaultPort' can not be referenced from a nonisolated autoclosure; this is an error in the Swift 6 language mode
- L138:92 [B main-actor isolation from nonisolated] main actor-isolated static property 'defaultPort' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L139:86 [B main-actor isolation from nonisolated] main actor-isolated static property 'passphraseKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L288:28 [B main-actor isolation from nonisolated] main actor-isolated static property 'browserPlayableExtensions' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L289:48 [B main-actor isolation from nonisolated] main actor-isolated static property 'nativeMovCodecs' can not be referenced from a nonisolated autoclosure; this is an error in the Swift 6 language mode

### VideoScan/PersonFinderModel+JobLifecycle.swift (6)

- L419:37 [C capture in @Sendable/concurrent closure] reference to captured var 'hits' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L1199:31 [C capture in @Sendable/concurrent closure] reference to captured var 'videoFiles' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L1200:36 [C capture in @Sendable/concurrent closure] reference to captured var 'videoFiles' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L1665:27 [C capture in @Sendable/concurrent closure] reference to captured var 'cachedRows' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L1669:16 [C capture in @Sendable/concurrent closure] reference to captured var 'hiddenBelowFloor' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L1670:60 [C capture in @Sendable/concurrent closure] reference to captured var 'hiddenBelowFloor' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VideoScanModel+VolumeLifecycle.swift (6)

- L68:17 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L81:17 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L85:17 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L86:17 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L99:17 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L100:17 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/FamilyTreeLaunchBundle.swift (5)

- L64:37 [C capture in @Sendable/concurrent closure] capture of 'rowsOut' with non-Sendable type 'UnsafeMutablePointer<[FamilyTreePersonSummary]>' in a '@Sendable' closure [#SendableClosureCaptures]
- L66:37 [C capture in @Sendable/concurrent closure] capture of 'identityOut' with non-Sendable type 'UnsafeMutablePointer<FamilyAssetIdentityDirectory?>' in a '@Sendable' closure [#SendableClosureCaptures]
- L70:37 [C capture in @Sendable/concurrent closure] capture of 'anchorsOut' with non-Sendable type 'UnsafeMutablePointer<[FamilyTreeAnchor]>' in a '@Sendable' closure [#SendableClosureCaptures]
- L71:37 [C capture in @Sendable/concurrent closure] capture of 'captionOut' with non-Sendable type 'UnsafeMutablePointer<String?>' in a '@Sendable' closure [#SendableClosureCaptures]
- L79:37 [C capture in @Sendable/concurrent closure] capture of 'indexesOut' with non-Sendable type 'UnsafeMutablePointer<[String : GedcomFamilyGraph.AncestorIndex]>' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/PersonFinderCompilation.swift (5)

- L90:67 [C capture in @Sendable/concurrent closure] capture of 'session' with non-Sendable type 'AVAssetExportSession' in a '@Sendable' closure [#SendableClosureCaptures]
- L643:74 [C capture in @Sendable/concurrent closure] reference to captured var 'clipsDone' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L643:93 [C capture in @Sendable/concurrent closure] reference to captured var 'clipsDone' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L656:44 [C capture in @Sendable/concurrent closure] reference to captured var 'clipsDone' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L657:50 [C capture in @Sendable/concurrent closure] reference to captured var 'clipsDone' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/ArcFaceEngine.swift (4)

- L6:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreML' [#AddPreconcurrencyImport]
- L190:17 [C capture in @Sendable/concurrent closure] capture of 'output' with non-Sendable type '(any MLFeatureProvider)?' in an isolated closure
- L190:30 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in an isolated closure
- L190:53 [C capture in @Sendable/concurrent closure] capture of 'input' with non-Sendable type 'any MLFeatureProvider' in an isolated closure

### VideoScanTests/HalliePronunciationDrillTests.swift (4)

- L132:52 [B main-actor isolation from nonisolated] main actor-isolated static property 'lexicon' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L143:34 [B main-actor isolation from nonisolated] main actor-isolated static property 'profiles' can not be referenced from a Sendable closure; this is an error in the Swift 6 language mode
- L144:31 [B main-actor isolation from nonisolated] main actor-isolated static property 'graph' can not be referenced from a Sendable closure; this is an error in the Swift 6 language mode
- L153:34 [B main-actor isolation from nonisolated] main actor-isolated static property 'speakers' can not be referenced from a Sendable closure; this is an error in the Swift 6 language mode

### VideoScan/HallieSpeaker.swift (3)

- L416:64 [E non-Sendable crossing isolation] converting non-Sendable function value to '@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void' may introduce data races
- L420:62 [E non-Sendable crossing isolation] converting non-Sendable function value to '@Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void' may introduce data races
- L575:17 [C capture in @Sendable/concurrent closure] capture of 'synthesizer' with non-Sendable type 'AVSpeechSynthesizer' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/IdentifyFamilyModel.swift (3)

- L144:34 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L244:45 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L247:45 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/PreviewSweepService.swift (3)

- L251:31 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L261:31 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L267:31 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/ArcFaceMLE5CrashTests.swift (3)

- L2:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreML' [#AddPreconcurrencyImport]
- L196:66 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]
- L243:66 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScanTests/HalliePronunciationPickerTests.swift (3)

- L38:53 [B main-actor isolation from nonisolated] main actor-isolated static property 'lexicon' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L56:34 [B main-actor isolation from nonisolated] main actor-isolated static property 'profiles' can not be referenced from a Sendable closure; this is an error in the Swift 6 language mode
- L67:34 [B main-actor isolation from nonisolated] main actor-isolated static property 'speakers' can not be referenced from a Sendable closure; this is an error in the Swift 6 language mode

### VideoScanTests/MediaStreamResolverTests.swift (3)

- L268:56 [B main-actor isolation from nonisolated] main actor-isolated class property 'passphraseKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L269:53 [B main-actor isolation from nonisolated] main actor-isolated class property 'portKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L282:57 [B main-actor isolation from nonisolated] main actor-isolated class property 'portKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/ArchiveAngelAttention.swift (2)

- L258:37 [B main-actor isolation from nonisolated] main actor-isolated static property 'attentionKinds' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L267:31 [B main-actor isolation from nonisolated] main actor-isolated static property 'attentionKinds' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/ArchiveAngelJob.swift (2)

- L261:21 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L874:35 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/ArchivistChatWindow.swift (2)

- L726:47 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'citationBasis' in a synchronous nonisolated context [#ActorIsolatedCall]
- L2509:46 [B main-actor isolation from nonisolated] call to main actor-isolated static method 'citationBasis' in a synchronous nonisolated context [#ActorIsolatedCall]

### VideoScan/FamilySearchPullCenter.swift (2)

- L16:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'UserNotifications' [#AddPreconcurrencyImport]
- L169:13 [C capture in @Sendable/concurrent closure] capture of 'center' with non-Sendable type 'UNUserNotificationCenter' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/HallieWebBridge.swift (2)

- L833:51 [B main-actor isolation from nonisolated] main actor-isolated static property 'maxDocumentBytes' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L835:29 [B main-actor isolation from nonisolated] main actor-isolated static property 'maxDocumentBytes' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/MediaFileOperationsWindow.swift (2)

- L42:49 [B main-actor isolation from nonisolated] main actor-isolated static property 'sceneID' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L43:30 [B main-actor isolation from nonisolated] main actor-isolated static property 'title' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/MediaPairComparator.swift (2)

- L629:17 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L647:27 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/PersonPhotoResolver.swift (2)

- L416:62 [B main-actor isolation from nonisolated] main actor-isolated static property 'shared' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L450:61 [B main-actor isolation from nonisolated] main actor-isolated static property 'shared' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/RealtimeFaceDetectionWindow.swift (2)

- L494:27 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L655:27 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/ThumbnailPrecache.swift (2)

- L239:49 [C capture in @Sendable/concurrent closure] reference to captured var 'model' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L289:45 [C capture in @Sendable/concurrent closure] reference to captured var 'model' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VideoScanModel+RelocateQueue.swift (2)

- L2:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'UserNotifications' [#AddPreconcurrencyImport]
- L283:13 [C capture in @Sendable/concurrent closure] capture of 'center' with non-Sendable type 'UNUserNotificationCenter' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/VideoScanModel+ScanExecution.swift (2)

- L533:38 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L656:42 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VideoScanModel+Thumbnail.swift (2)

- L859:31 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]
- L893:31 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/ArcFaceModelLoaderTests.swift (2)

- L2:1 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'CoreML' [#AddPreconcurrencyImport]
- L131:66 [C capture in @Sendable/concurrent closure] capture of 'model' with non-Sendable type 'MLModel' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScanTests/BackupAttestationJournalTests.swift (2)

- L20:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L106:54 [C capture in @Sendable/concurrent closure] capture of 'seen' with non-Sendable type '[VideoRecord]' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScanTests/BackupAttestationSensorTests.swift (2)

- L24:11 [G @preconcurrency import hint] add '@preconcurrency' to suppress 'Sendable'-related warnings from module 'VideoScanCore' [#AddPreconcurrencyImport]
- L210:54 [C capture in @Sendable/concurrent closure] capture of 'seen' with non-Sendable type '[VideoRecord]' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScanTests/RemoteViewerIsolationTests.swift (2)

- L71:53 [B main-actor isolation from nonisolated] main actor-isolated class property 'portKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode
- L72:42 [B main-actor isolation from nonisolated] main actor-isolated class property 'passphraseKey' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/ArchiveAngelEvidenceStore.swift (1)

- L168:74 [B main-actor isolation from nonisolated] main actor-isolated static property 'filename' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/ArchiveAngelJob+Evidence.swift (1)

- L49:62 [B main-actor isolation from nonisolated] main actor-isolated static property 'evidenceFreshness' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/DeleteDuplicatesJob.swift (1)

- L695:28 [B main-actor isolation from nonisolated] main actor-isolated static property 'slotCapacity' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/FamilyKinshipOverlay.swift (1)

- L389:43 [B main-actor isolation from nonisolated] converting function value of type '@MainActor @Sendable (POIProfile) -> ArchivistGraphProfileSnapshot' to '(POIProfile) -> ArchivistGraphProfileSnapshot' loses global actor 'MainActor'; this is an error in the Swift 6 language mode

### VideoScan/FamilySearchPullCoordinator.swift (1)

- L129:57 [B main-actor isolation from nonisolated] main actor-isolated static property 'defaultTimeout' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/FamilyTreeLiveModel.swift (1)

- L952:22 [C capture in @Sendable/concurrent closure] capture of 'buffer' with non-Sendable type 'UnsafeMutableBufferPointer<FamilyTreePersonSummary>' in a '@Sendable' closure [#SendableClosureCaptures]

### VideoScan/GatedOutcomeLogBatcher.swift (1)

- L52:66 [B main-actor isolation from nonisolated] main actor-isolated static property 'defaultFlushEvery' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/HallieTurnExecutor+Relationship.swift (1)

- L317:36 [C capture in @Sendable/concurrent closure] reference to captured var 'subjects' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/HelperAudioRepair.swift (1)

- L312:43 [E non-Sendable crossing isolation] passing non-Sendable parameter 'onChange' to function expecting a '@Sendable' closure

### VideoScan/RealtimeCatalogScanWindow.swift (1)

- L510:27 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VideoScanModel+ArchiveAngelBufferHygiene.swift (1)

- L212:27 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VideoScanModel+DateInference.swift (1)

- L877:30 [B main-actor isolation from nonisolated] main actor-isolated static property 'folderYearPriorRange' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScan/VideoScanModel+Filmstrip.swift (1)

- L306:49 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScan/VideoScanModel+ProbeEngine.swift (1)

- L113:27 [C capture in @Sendable/concurrent closure] reference to captured var 'self' in concurrently-executing code; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/ArchiveAngelSkipEntryTests.swift (1)

- L322:29 [B main-actor isolation from nonisolated] class property 'isMainThread' is unavailable from asynchronous contexts; Work intended for the main actor should be marked with @MainActor; this is an error in the Swift 6 language mode

### VideoScanTests/CatalogStoreAsyncSaveTests.swift (1)

- L252:16 [H other] class method 'sleep' is unavailable from asynchronous contexts; Use Task.sleep(until:clock:) instead.; this is an error in the Swift 6 language mode

### VideoScanTests/FamilyAssetStoreTests.swift (1)

- L442:18 [C capture in @Sendable/concurrent closure] capture of 'fm' with non-Sendable type 'FileManager' in a '@Sendable' closure; this is an error in the Swift 6 language mode [#SendableClosureCaptures]

### VideoScanTests/FamilyTreeBookmarkDiscoveryTests.swift (1)

- L44:76 [B main-actor isolation from nonisolated] main actor-isolated static property 'tree' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScanTests/HallieGH184RoutesShellTests.swift (1)

- L38:63 [B main-actor isolation from nonisolated] main actor-isolated static property 'tree' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

### VideoScanTests/HalliePersonaQuestionTests.swift (1)

- L35:54 [B main-actor isolation from nonisolated] main actor-isolated static property 'tree' can not be referenced from a nonisolated context; this is an error in the Swift 6 language mode

