// VideoScanTests.swift — this file has been split into domain-specific test files:
//
//   ModelTests.swift            — StreamType, VideoRecord, enums, POIStorage, CombineJobStatus
//   FormattingTests.swift       — Formatting helpers
//   CorrelatorTests.swift       — Audio/video correlation
//   DuplicateDetectorTests.swift — Duplicate detection, scoring, deletion safety
//   FFProbeTests.swift          — FFProbe decoding, integration, extractMetadata, diagnosis
//   MxfTests.swift              — MXF header parser, codec identification, Avb parser
//   ScanEngineTests.swift       — Semaphore, memory, pause, discovery, volumes, media generator
//   CatalogTests.swift          — Import/export, ScanContext, skip sets, volume compare
//   CombineTests.swift          — CombineEngine, codec compat, navigation, online subs, technique
//   ScanConfigurationTests.swift — PersonFinder scan config, face loading, engine resolution
//   TestHelpers.swift           — Shared helpers (TestCounter, makeDuplicateRecord, testFixturesDir)
