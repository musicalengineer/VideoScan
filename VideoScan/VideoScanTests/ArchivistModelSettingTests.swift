import Testing
import Foundation
@testable import VideoScan

// MARK: - The model selector writes the key every asking path reads
//
// Rick, 2026-09-01: "we already have settings for Archivist Brain so let's
// put the selector in there." Until now the tag lived in five source files
// and a `defaults write` — which, as the host list above it says, "is not a
// setting so much as a rumour."
//
// The one thing that must not drift is the KEY. ArchivistChatWindow,
// ArchivistAskField and HallieWebAccess all read
// "archivist.ollamaModel"; a pane that wrote anywhere else would look like
// it worked and change nothing.

struct ArchivistModelSettingTests {

    @Test func thePaneWritesTheSameKeyEveryAskingPathReads() {
        #expect(ArchivistEndpointSettings.modelKey == "archivist.ollamaModel")
    }

    /// An isolated store, never the real plist — a test that writes the
    /// user's own preferences is a settings-pollution bug of its own.
    private func store(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "test.\(name).\(UUID().uuidString)")!
        return suite
    }

    @Test func anAbsentKeyFallsBackToTheShippedDefault() {
        let defaults = store("absent")
        let resolved = defaults.string(forKey: ArchivistEndpointSettings.modelKey)
            ?? HallieBrain.defaultModel
        #expect(resolved == HallieBrain.defaultModel)
        #expect(HallieBrain.defaultModel == "qwen3.8:27b-mlx")
    }

    @Test func aStoredTagWinsOverTheShippedDefault() {
        let defaults = store("stored")
        defaults.set("qwen3.6:35b-a3b-nvfp4", forKey: ArchivistEndpointSettings.modelKey)
        let resolved = defaults.string(forKey: ArchivistEndpointSettings.modelKey)
            ?? HallieBrain.defaultModel
        #expect(resolved == "qwen3.6:35b-a3b-nvfp4",
                "switching back must not need a rebuild")
    }

    // MARK: The menu is built from the host that will actually answer

    @Test func installedModelsAreReadFromTheTagsEndpoint() async {
        var translator = OllamaQueryTranslator()
        translator.host = "example.local"
        translator.transport = .fake { url, _ in
            #expect(url.hasSuffix("/api/tags"))
            return .ok("""
            {"models":[{"name":"qwen3.8:27b-mlx"},{"name":"qwen3.6:35b-a3b-nvfp4"}]}
            """)
        }
        let tags = await translator.installedModels()
        // Sorted so the menu order does not depend on the server's.
        #expect(tags == ["qwen3.6:35b-a3b-nvfp4", "qwen3.8:27b-mlx"])
    }

    /// An unreachable host returns EMPTY rather than throwing, which is what
    /// switches the pane to a free-text field. An empty menu you cannot type
    /// your way out of would be a dead end.
    @Test func anUnreachableHostYieldsAnEmptyListNotAnError() async {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in .down("connection refused") }
        #expect(await translator.installedModels().isEmpty)
    }

    @Test func malformedJSONIsEmptyRatherThanACrash() async {
        var translator = OllamaQueryTranslator()
        translator.transport = .fake { _, _ in .ok("{\"models\": \"not-an-array\"}") }
        #expect(await translator.installedModels().isEmpty)
    }
}
