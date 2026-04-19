//
//  PDFReport.swift
//  XOInventory
//
//  Builds a paginated PDF inventory report using Core Graphics.
//  Landscape letter, header + summary + zebra-striped table, page numbers.
//

import Foundation
import AppKit
import CoreGraphics

enum PDFReport {
    // MARK: - Page geometry (landscape letter)

    private static let pageSize  = CGSize(width: 792, height: 612) // 11" x 8.5"
    private static let margin: CGFloat = 36                         // 0.5"
    private static let headerHeight: CGFloat = 70
    private static let summaryHeight: CGFloat = 54
    private static let footerHeight: CGFloat = 24
    private static let rowHeight: CGFloat = 22
    private static let tableHeaderHeight: CGFloat = 26

    // MARK: - Column layout

    private struct Column {
        let title: String
        let width: CGFloat
        let alignment: NSTextAlignment
        let key: (VMRowData) -> String
    }

    // MARK: - Public

    /// Render the inventory as PDF and return the raw data.
    static func build(vms: [VM],
                      diskByVM: [String: Int64],
                      hostDisplay: String) -> Data {
        let rows = vms.map { VMRowData(vm: $0, diskBytes: diskByVM[$0.uuid] ?? 0) }

        // Column widths sized to usable page width (792 - 2*36 = 720pt).
        let columns: [Column] = [
            Column(title: "Name",     width: 170, alignment: .left,   key: { $0.name }),
            Column(title: "State",    width: 70,  alignment: .left,   key: { $0.powerState }),
            Column(title: "IP",       width: 110, alignment: .left,   key: { $0.ip }),
            Column(title: "vCPUs",    width: 55,  alignment: .right,  key: { $0.cpus }),
            Column(title: "Memory",   width: 85,  alignment: .right,  key: { $0.memory }),
            Column(title: "Disk",     width: 85,  alignment: .right,  key: { $0.disk }),
            Column(title: "OS",       width: 145, alignment: .left,   key: { $0.os })
        ]

        let summary = Summary(rows: rows)
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        // Pre-compute pagination: how many rows fit on each page?
        // First page: header + summary + table header + rows
        // Subsequent pages: table header + rows (no summary repeat)
        let firstPageRowArea = pageSize.height - (2 * margin) - headerHeight - summaryHeight - tableHeaderHeight - footerHeight
        let subsequentPageRowArea = pageSize.height - (2 * margin) - tableHeaderHeight - footerHeight
        let rowsOnFirstPage = max(1, Int(firstPageRowArea / rowHeight))
        let rowsOnOtherPages = max(1, Int(subsequentPageRowArea / rowHeight))

        // Split rows across pages
        var pages: [[VMRowData]] = []
        var remaining = rows[...]
        let firstSlice = remaining.prefix(rowsOnFirstPage)
        pages.append(Array(firstSlice))
        remaining = remaining.dropFirst(firstSlice.count)
        while !remaining.isEmpty {
            let slice = remaining.prefix(rowsOnOtherPages)
            pages.append(Array(slice))
            remaining = remaining.dropFirst(slice.count)
        }
        if pages.isEmpty { pages = [[]] } // at least one page, even if no VMs

        let totalPages = pages.count

        // Draw each page
        for (index, pageRows) in pages.enumerated() {
            pdf.beginPDFPage(nil)

            // Core Graphics uses a bottom-left origin by default. Flip so (0,0) is top-left
            // for easier top-down layout.
            pdf.saveGState()
            pdf.translateBy(x: 0, y: pageSize.height)
            pdf.scaleBy(x: 1, y: -1)

            var cursorY = margin

            if index == 0 {
                drawHeader(in: pdf, at: &cursorY, hostDisplay: hostDisplay, vmCount: rows.count)
                drawSummary(in: pdf, at: &cursorY, summary: summary)
            }

            drawTableHeader(in: pdf, at: &cursorY, columns: columns)
            drawRows(in: pdf, at: &cursorY, rows: pageRows, columns: columns,
                     startIndex: pages[..<index].reduce(0) { $0 + $1.count })

            pdf.restoreGState()
            drawFooter(in: pdf, pageIndex: index, totalPages: totalPages,
                       hostDisplay: hostDisplay)
            pdf.endPDFPage()
        }

        pdf.closePDF()
        return data as Data
    }

    // MARK: - Drawing: header / summary / footer

    private static func drawHeader(in ctx: CGContext,
                                   at cursorY: inout CGFloat,
                                   hostDisplay: String,
                                   vmCount: Int) {
        let titleRect = CGRect(x: margin, y: cursorY, width: pageSize.width - 2*margin, height: 26)
        draw(text: "XCP-NG VM Inventory",
             in: titleRect,
             font: NSFont.systemFont(ofSize: 20, weight: .bold),
             color: .black,
             alignment: .left,
             context: ctx)

        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        draw(text: date,
             in: titleRect,
             font: NSFont.systemFont(ofSize: 11, weight: .regular),
             color: NSColor(white: 0.4, alpha: 1),
             alignment: .right,
             context: ctx)

        let subtitleRect = CGRect(x: margin, y: cursorY + 28,
                                  width: pageSize.width - 2*margin, height: 16)
        draw(text: "Host: \(hostDisplay)   ·   \(vmCount) VM\(vmCount == 1 ? "" : "s")",
             in: subtitleRect,
             font: NSFont.systemFont(ofSize: 11, weight: .regular),
             color: NSColor(white: 0.35, alpha: 1),
             alignment: .left,
             context: ctx)

        // Separator line
        let lineY = cursorY + headerHeight - 8
        ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: lineY))
        ctx.addLine(to: CGPoint(x: pageSize.width - margin, y: lineY))
        ctx.strokePath()

        cursorY += headerHeight
    }

    private static func drawSummary(in ctx: CGContext,
                                    at cursorY: inout CGFloat,
                                    summary: Summary) {
        let items: [(String, String)] = [
            ("Running", "\(summary.running)"),
            ("Halted",  "\(summary.halted)"),
            ("Other",   "\(summary.other)"),
            ("Total vCPUs", "\(summary.totalCPUs)"),
            ("Total RAM",   summary.totalRAMDisplay),
            ("Total Disk",  summary.totalDiskDisplay)
        ]

        let boxWidth = (pageSize.width - 2*margin) / CGFloat(items.count)
        for (i, item) in items.enumerated() {
            let x = margin + CGFloat(i) * boxWidth
            let labelRect = CGRect(x: x, y: cursorY + 4, width: boxWidth, height: 14)
            let valueRect = CGRect(x: x, y: cursorY + 20, width: boxWidth, height: 22)

            draw(text: item.0.uppercased(),
                 in: labelRect,
                 font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                 color: NSColor(white: 0.5, alpha: 1),
                 alignment: .left,
                 context: ctx)

            draw(text: item.1,
                 in: valueRect,
                 font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                 color: .black,
                 alignment: .left,
                 context: ctx)
        }

        // Bottom border of summary strip
        let lineY = cursorY + summaryHeight - 4
        ctx.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: lineY))
        ctx.addLine(to: CGPoint(x: pageSize.width - margin, y: lineY))
        ctx.strokePath()

        cursorY += summaryHeight
    }

    private static func drawFooter(in ctx: CGContext,
                                   pageIndex: Int,
                                   totalPages: Int,
                                   hostDisplay: String) {
        // Footer is drawn in native (bottom-left origin) coordinates because the
        // caller already popped the flipped GState before calling us.
        let y = margin - 18
        let rect = CGRect(x: margin, y: y, width: pageSize.width - 2*margin, height: 14)
        let left = "XOInventory — \(hostDisplay)"
        let right = "Page \(pageIndex + 1) of \(totalPages)"

        // Convert to flipped so drawInRect on NSAttributedString renders upright.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        let flippedRect = CGRect(x: rect.origin.x,
                                 y: pageSize.height - rect.origin.y - rect.height,
                                 width: rect.width,
                                 height: rect.height)

        draw(text: left,
             in: flippedRect,
             font: NSFont.systemFont(ofSize: 9),
             color: NSColor(white: 0.5, alpha: 1),
             alignment: .left,
             context: ctx)
        draw(text: right,
             in: flippedRect,
             font: NSFont.systemFont(ofSize: 9),
             color: NSColor(white: 0.5, alpha: 1),
             alignment: .right,
             context: ctx)
        ctx.restoreGState()
    }

    // MARK: - Drawing: table

    private static func drawTableHeader(in ctx: CGContext,
                                        at cursorY: inout CGFloat,
                                        columns: [Column]) {
        // Filled header background
        let bgRect = CGRect(x: margin, y: cursorY,
                            width: pageSize.width - 2*margin, height: tableHeaderHeight)
        ctx.setFillColor(NSColor(white: 0.94, alpha: 1).cgColor)
        ctx.fill(bgRect)

        // Top + bottom borders
        ctx.setStrokeColor(NSColor(white: 0.75, alpha: 1).cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: cursorY))
        ctx.addLine(to: CGPoint(x: pageSize.width - margin, y: cursorY))
        ctx.move(to: CGPoint(x: margin, y: cursorY + tableHeaderHeight))
        ctx.addLine(to: CGPoint(x: pageSize.width - margin, y: cursorY + tableHeaderHeight))
        ctx.strokePath()

        var x = margin + 6
        for col in columns {
            let rect = CGRect(x: x, y: cursorY + 6, width: col.width - 12, height: tableHeaderHeight - 12)
            draw(text: col.title.uppercased(),
                 in: rect,
                 font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                 color: NSColor(white: 0.35, alpha: 1),
                 alignment: col.alignment,
                 context: ctx)
            x += col.width
        }

        cursorY += tableHeaderHeight
    }

    private static func drawRows(in ctx: CGContext,
                                 at cursorY: inout CGFloat,
                                 rows: [VMRowData],
                                 columns: [Column],
                                 startIndex: Int) {
        for (i, row) in rows.enumerated() {
            let globalIndex = startIndex + i
            let isAlt = globalIndex % 2 == 1
            let rowRect = CGRect(x: margin, y: cursorY,
                                 width: pageSize.width - 2*margin, height: rowHeight)

            if isAlt {
                ctx.setFillColor(NSColor(white: 0.975, alpha: 1).cgColor)
                ctx.fill(rowRect)
            }

            // Row bottom border
            ctx.setStrokeColor(NSColor(white: 0.9, alpha: 1).cgColor)
            ctx.setLineWidth(0.25)
            ctx.move(to: CGPoint(x: margin, y: cursorY + rowHeight))
            ctx.addLine(to: CGPoint(x: pageSize.width - margin, y: cursorY + rowHeight))
            ctx.strokePath()

            // Cell contents
            var x = margin + 6
            for (colIndex, col) in columns.enumerated() {
                let rect = CGRect(x: x, y: cursorY + 5, width: col.width - 12, height: rowHeight - 8)
                var color: NSColor = .black
                var weight: NSFont.Weight = (colIndex == 0 && row.isRunning) ? .semibold : .regular
                if colIndex == 1 {
                    color = PDFReport.stateColor(row.powerState)
                    weight = .semibold
                } else if colIndex > 1 && (col.key(row) == "—" || col.key(row).isEmpty) {
                    color = NSColor(white: 0.65, alpha: 1)
                }

                let font: NSFont = (colIndex == 2 || colIndex >= 3 && colIndex <= 5)
                    ? .monospacedDigitSystemFont(ofSize: 10, weight: weight)
                    : .systemFont(ofSize: 10, weight: weight)

                draw(text: col.key(row),
                     in: rect,
                     font: font,
                     color: color,
                     alignment: col.alignment,
                     context: ctx,
                     truncate: true)
                x += col.width
            }

            cursorY += rowHeight
        }
    }

    // MARK: - Text drawing

    private static func draw(text: String,
                             in rect: CGRect,
                             font: NSFont,
                             color: NSColor,
                             alignment: NSTextAlignment,
                             context: CGContext,
                             truncate: Bool = false) {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        if truncate { para.lineBreakMode = .byTruncatingTail }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: para
        ]

        // NSAttributedString.draw wants the current NSGraphicsContext to point at our CGContext.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSString(string: text).draw(in: rect, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func stateColor(_ state: String) -> NSColor {
        switch state.lowercased() {
        case "running":               return NSColor.systemGreen.blended(withFraction: 0.2, of: .black) ?? .systemGreen
        case "halted":                return NSColor(white: 0.45, alpha: 1)
        case "paused", "suspended":   return NSColor.systemOrange
        default:                      return NSColor(white: 0.45, alpha: 1)
        }
    }
}

// MARK: - Local row wrapper + summary

private struct VMRowData {
    let vm: VM
    let diskBytes: Int64

    var name: String { vm.nameLabel }
    var powerState: String { vm.powerState }
    var ip: String { vm.ipDisplay }
    var cpus: String { vm.cpuDisplay }
    var memory: String { vm.memoryDisplay }
    var disk: String {
        diskBytes > 0 ? VM.byteFormatter.string(fromByteCount: diskBytes) : "—"
    }
    var os: String { vm.os ?? "—" }
    var isRunning: Bool { vm.isRunning }
}

private struct Summary {
    let running: Int
    let halted: Int
    let other: Int
    let totalCPUs: Int
    let totalRAMBytes: Int64
    let totalDiskBytes: Int64

    init(rows: [VMRowData]) {
        var run = 0, halt = 0, oth = 0, cpus = 0
        var ram: Int64 = 0, disk: Int64 = 0
        for r in rows {
            switch r.powerState.lowercased() {
            case "running": run += 1
            case "halted":  halt += 1
            default:        oth += 1
            }
            cpus += r.vm.cpus ?? 0
            ram += r.vm.memoryBytes ?? 0
            disk += r.diskBytes
        }
        self.running = run
        self.halted = halt
        self.other = oth
        self.totalCPUs = cpus
        self.totalRAMBytes = ram
        self.totalDiskBytes = disk
    }

    var totalRAMDisplay: String {
        VM.byteFormatter.string(fromByteCount: totalRAMBytes)
    }
    var totalDiskDisplay: String {
        totalDiskBytes > 0 ? VM.byteFormatter.string(fromByteCount: totalDiskBytes) : "—"
    }
}
