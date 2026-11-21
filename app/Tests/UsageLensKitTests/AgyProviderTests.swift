import Foundation
import XCTest
@testable import UsageLensKit

final class AgyProviderTests: XCTestCase {
    func testProviderCatalogAgyMetadataAndDefaultOrdering() {
        let agy = ProviderCatalog.agy
        XCTAssertEqual(agy.id, "agy")
        XCTAssertEqual(agy.displayName, "AGY")
        XCTAssertEqual(agy.probeRelativePath, "probes/agy.py")
        XCTAssertFalse(agy.requiresAPIKey)
        XCTAssertFalse(agy.requiresAccount)
        XCTAssertFalse(agy.requiresCredentials)

        // AGY 位于 Codex 之后，并默认启用。
        let availableIDs = ProviderCatalog.available.map(\.id)
        XCTAssertEqual(availableIDs, ["codex", "agy", "gemini", "opencode", "deepseek"])
        XCTAssertEqual(ProviderCatalog.defaultActiveIDs, ["codex", "agy", "gemini", "opencode"])
        XCTAssertEqual(ProviderCatalog.provider(id: "agy"), agy)
    }

    func testProbeRunnerAgyTimeoutBudget() {
        let runner = ProbeRunner(
            deepSeekAPIKeyLoader: { nil },
            geminiAccountLoader: { nil }
        )
        XCTAssertEqual(runner.effectiveTimeout(for: ProviderCatalog.agy), 15)
        XCTAssertEqual(runner.effectiveTimeout(for: ProviderCatalog.gemini), 15)
        XCTAssertEqual(runner.effectiveTimeout(for: ProviderCatalog.codex), 6)
    }

    func testProbeRunnerEnvIsolationForAgyAndOtherProviders() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("usage-lens-agy-env-\(UUID().uuidString)", isDirectory: true)
        let probes = root.appendingPathComponent("probes", isDirectory: true)
        try fm.createDirectory(at: probes, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let echoScript = """
        import json, os
        has_agy_token = "AGY_ACCESS_TOKEN" in os.environ
        agy_keys = sorted(k for k in os.environ if k.startswith("AGY_"))
        has_gemini = "GEMINI_ACCESS_TOKEN" in os.environ
        has_deepseek = "DEEPSEEK_API_KEY" in os.environ
        print(json.dumps({
            "schema": "usage-lens/probe@1",
            "provider": "test",
            "windows": [],
            "warnings": [
                "has_agy_token=" + str(has_agy_token),
                "has_any_agy=" + str(bool(agy_keys)),
                "has_gemini=" + str(has_gemini),
                "has_deepseek=" + str(has_deepseek),
            ],
            "error": None
        }))
        """
        try echoScript.write(to: probes.appendingPathComponent("agy.py"), atomically: true, encoding: .utf8)
        try echoScript.write(to: probes.appendingPathComponent("codex.py"), atomically: true, encoding: .utf8)
        try echoScript.write(to: probes.appendingPathComponent("gemini.py"), atomically: true, encoding: .utf8)

        // 模拟父进程环境带了 AGY_* 变量，确认仅 AGY 探针能看到，其他探针会被剥离。
        let previousAgyToken = getenv("AGY_ACCESS_TOKEN").map { String(cString: $0) }
        setenv("AGY_ACCESS_TOKEN", "ya29.parent_env_synthetic_only", 1)
        defer {
            if let previousAgyToken {
                setenv("AGY_ACCESS_TOKEN", previousAgyToken, 1)
            } else {
                unsetenv("AGY_ACCESS_TOKEN")
            }
        }

        let runner = ProbeRunner(
            root: root,
            timeout: 5,
            deepSeekAPIKeyLoader: { "sk-synthetic-deepseek-only" },
            geminiAccountLoader: {
                GeminiAccount(
                    email: "gemini@example.com",
                    accessToken: "ya29.synthetic-gemini-only",
                    projectID: "proj-g"
                )
            }
        )

        let agyReport = await runner.report(for: ProviderCatalog.agy)
        XCTAssertEqual(
            agyReport.warnings,
            ["has_agy_token=True", "has_any_agy=True", "has_gemini=False", "has_deepseek=False"]
        )

        let codexReport = await runner.report(for: ProviderCatalog.codex)
        XCTAssertEqual(
            codexReport.warnings,
            ["has_agy_token=False", "has_any_agy=False", "has_gemini=False", "has_deepseek=False"]
        )

        let geminiReport = await runner.report(for: ProviderCatalog.gemini)
        XCTAssertEqual(
            geminiReport.warnings,
            ["has_agy_token=False", "has_any_agy=False", "has_gemini=True", "has_deepseek=False"]
        )
    }
}
