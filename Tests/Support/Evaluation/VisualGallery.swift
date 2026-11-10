import Foundation
import SwiftGraph

#if canImport(CryptoKit)
import CryptoKit
#endif

enum VisualGallery {
    static func currentFindings(_ row: VisualResult) -> String {
        let counts = Dictionary(grouping: row.metrics?.findings ?? [], by: \.kind).mapValues(\.count)
        return counts.keys.sorted().map { "\($0): \(counts[$0]!)" }.joined(separator: ", ")
    }

    static func report(_ run: VisualManifest) -> String {
        var lines = [
            "# SwiftGraph visual evaluation", "",
            "\(run.cases.count) cases · \(run.cases.filter(\.failed).count) failed · \(run.cases.filter { $0.status == "changed" }.count) changed · \(run.cases.filter { $0.status == "skipped" }.count) skipped",
            "", "Open [the gallery](index.html) for images, overlays and detailed metrics.", "",
            "| Case | Status | Current findings | Review increases |", "| --- | --- | --- | --- |",
        ]
        for row in run.cases {
            lines.append(
                "| \(row.id) | \(row.status) | \(currentFindings(row)) | \((row.difference?.qualityFlags ?? []).joined(separator: ", ")) \(row.error?.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/") ?? "") |"
            )
        }
        lines += [
            "", "## Agent review", "",
            "Inspect flagged cases and contact sheets. For each finding record: case ID, severity, image/element evidence, proposed change, and before/after outcome. Increased metrics are review prompts, not a universal quality score. Never accept a baseline solely to silence a finding.",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    static func html(_ run: VisualManifest) -> String {
        let esc = VisualRenderer.escape
        var body = """
            <!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>SwiftGraph visual evaluation</title><style>
            *{box-sizing:border-box}body{margin:0;background:#f1f5f9;color:#0f172a;font:14px system-ui,sans-serif}header{padding:24px 32px;background:#0f172a;color:white}main{padding:24px;max-width:1600px;margin:auto}h1{margin:0 0 8px}a{color:#2563eb}header a{color:#93c5fd}.filters{position:sticky;top:0;background:#e2e8f0;padding:14px;z-index:2;display:flex;gap:12px;flex-wrap:wrap}input,select{padding:8px;border:1px solid #94a3b8;border-radius:4px}.case{background:white;border:1px solid #cbd5e1;border-radius:8px;margin:18px 0;padding:20px}.case[data-status=contract-failure],.case[data-status=error]{border:2px solid #dc2626}.status{font:12px monospace;background:#e2e8f0;padding:4px 8px;border-radius:4px}.images{display:flex;gap:16px}.images figure{flex:1;min-width:0;margin:12px 0}.images img{width:100%;height:360px;object-fit:contain;border:1px solid #e2e8f0}figcaption{color:#475569;margin:6px 0}table{border-collapse:collapse}td,th{text-align:left;padding:5px 12px;border-bottom:1px solid #e2e8f0}pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px}.sheets{display:flex;gap:12px;flex-wrap:wrap}.sheets img{width:240px;border:1px solid #cbd5e1}.warning{color:#9a3412}summary{cursor:pointer;margin:10px 0}small{color:#64748b}[hidden]{display:none!important}@media(max-width:700px){.images{display:block}main{padding:10px}}</style>
            <header><h1>SwiftGraph visual evaluation</h1><div>\(run.cases.count) cases · \(run.cases.filter(\.failed).count) failed · Geometry contracts fail; visual changes invite review.</div><p><a href="manifest.json">Manifest</a> · <a href="report.md">Review report</a></p></header><main>
            <div class="filters"><input id="search" placeholder="Find a case" aria-label="Find a case"><select id="family" aria-label="Family"><option value="">All families</option>
            """
        for family in Set(run.cases.map(\.family)).sorted() { body += "<option>\(esc(family))</option>" }
        body += "</select><select id=\"status\" aria-label=\"Status\"><option value=\"\">All statuses</option>"
        for status in Set(run.cases.map(\.status)).sorted() { body += "<option>\(esc(status))</option>" }
        body +=
            "</select><span id=\"count\"></span></div><details><summary>Contact sheets</summary><div class=\"sheets\">"
        for sheet in run.contactSheets {
            body += "<a href=\"\(esc(sheet))\"><img loading=\"lazy\" src=\"\(esc(sheet))\" alt=\"Contact sheet\"></a>"
        }
        body += "</div></details>"
        for row in run.cases {
            let dir = "cases/\(row.id)"
            body +=
                "<article class=\"case\" data-family=\"\(esc(row.family))\" data-status=\"\(esc(row.status))\"><span class=\"status\">\(esc(row.status))</span><h2>\(esc(row.id))</h2><p>\(esc(row.title))</p>"
            if let notes = row.notes, !notes.isEmpty {
                body += "<details><summary>Execution and presentation notes</summary><ul>"
                for note in notes { body += "<li>\(esc(note))</li>" }
                body += "</ul></details>"
            }
            let findings = currentFindings(row)
            if !findings.isEmpty { body += "<p class=\"warning\">Current findings: \(esc(findings))</p>" }
            if let error = row.error { body += "<pre class=\"warning\">\(esc(error))</pre>" }
            if let diff = row.difference {
                body +=
                    "<p>Changed nodes: \(esc(diff.changedNodes.joined(separator: ", "))) · Changed edges: \(esc(diff.changedEdges.joined(separator: ", ")))\(diff.configurationChanged ? " · Recipe changed" : "")</p>"
                if !diff.qualityFlags.isEmpty {
                    body +=
                        "<p class=\"warning\">Review increases: \(esc(diff.qualityFlags.joined(separator: ", ")))</p>"
                }
            }
            if row.hasSnapshot {
                body += "<div class=\"images\">"
                for name in row.hasBefore ? ["before", "current"] : ["current"] {
                    body +=
                        "<figure><a href=\"\(dir)/\(name).svg\"><img loading=\"lazy\" src=\"\(dir)/\(name).png\" alt=\"\(esc(row.id)) \(name)\"></a><figcaption>\(name) · <a href=\"\(dir)/\(name).svg\">Zoom SVG</a> · <a href=\"\(dir)/\(name).png\">PNG</a></figcaption></figure>"
                }
                body +=
                    "</div><p><a href=\"\(dir)/geometry.json\">Geometry</a> · <a href=\"\(dir)/metrics.json\">Metrics</a>"
                if row.hasBefore {
                    body += " · <a href=\"\(dir)/overlay.svg\">Overlay (magenta before, cyan current)</a>"
                }
                body += "</p>"
            }
            if let metrics = row.metrics {
                if !metrics.failures.isEmpty {
                    body +=
                        "<pre class=\"warning\">"
                        + esc(
                            metrics.failures.map { "\($0.kind): \($0.elements.joined(separator: ", "))" }
                                .joined(separator: "\n")
                        ) + "</pre>"
                }
                body +=
                    "<details><summary>Metrics and diagnostics</summary><table><tr><th>Metric</th><th>Current</th><th>Delta</th></tr>"
                for key in metrics.values.keys.sorted() {
                    body +=
                        "<tr><td>\(esc(key))</td><td>\(VisualRenderer.number(metrics.values[key]!))</td><td>\(VisualRenderer.number(row.difference?.metricDeltas[key] ?? 0))</td></tr>"
                }
                body +=
                    "</table><pre>"
                    + esc(
                        metrics.findings.map { "\($0.kind): \($0.elements.joined(separator: ", "))" }
                            .joined(separator: "\n")
                    ) + "</pre></details>"
            }
            body += "</article>"
        }
        body += """
            <script>const controls=['search','family','status'].map(id=>document.getElementById(id));function filter(){let n=0;document.querySelectorAll('.case').forEach(card=>{const show=card.textContent.toLowerCase().includes(controls[0].value.toLowerCase())&&(!controls[1].value||card.dataset.family===controls[1].value)&&(!controls[2].value||card.dataset.status===controls[2].value);card.hidden=!show;if(show)n++;});document.getElementById('count').textContent=n+' visible';}controls.forEach(c=>c.addEventListener('input',filter));filter();</script></main></html>
            """
        return body
    }
}
