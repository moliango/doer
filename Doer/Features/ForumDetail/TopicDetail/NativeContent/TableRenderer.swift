import CookedHTML
import UIKit

enum TableRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .table = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .table(let headers, let rows) = block else { return UIView() }

        let columnCount = max(
            headers.count,
            rows.map(\.count).max() ?? 0
        )
        guard columnCount > 0 else { return UIView() }

        let cellPaddingV: CGFloat = 10
        let cellPaddingH: CGFloat = 12
        let separatorColor = UIColor.separator.withAlphaComponent(0.28)

        // MARK: - Build grid and measure natural column widths

        // All rows (headers first, then data) as [[ContentBlock]]
        var allRows: [[[ContentBlock]]] = []
        var isHeaderRow: [Bool] = []
        if !headers.isEmpty {
            allRows.append(headers)
            isHeaderRow.append(true)
        }
        for row in rows {
            allRows.append(row)
            isHeaderRow.append(false)
        }

        var columnMaxWidths: [CGFloat] = Array(repeating: 0, count: columnCount)
        for row in allRows {
            for col in 0..<columnCount {
                let cellBlocks = col < row.count ? row[col] : []
                let naturalWidth = estimateNaturalWidth(of: cellBlocks, config: config) + cellPaddingH * 2
                columnMaxWidths[col] = max(columnMaxWidths[col], naturalWidth)
            }
        }

        // MARK: - Water-filling column width allocation

        let availableWidth = max(config.contentWidth, CGFloat(columnCount) * 40)
        var columnWidths = Array(repeating: CGFloat(0), count: columnCount)
        var flexibleCols = Set(0..<columnCount)
        var remainingWidth = availableWidth

        var changed = true
        while changed {
            changed = false
            guard !flexibleCols.isEmpty else { break }
            let fairShare = remainingWidth / CGFloat(flexibleCols.count)
            for col in flexibleCols {
                if columnMaxWidths[col] <= fairShare {
                    columnWidths[col] = columnMaxWidths[col]
                    remainingWidth -= columnMaxWidths[col]
                    flexibleCols.remove(col)
                    changed = true
                }
            }
        }

        if !flexibleCols.isEmpty {
            let flexTotal = flexibleCols.map({ columnMaxWidths[$0] }).reduce(0, +)
            for col in flexibleCols {
                if flexTotal > 0 {
                    columnWidths[col] = remainingWidth * (columnMaxWidths[col] / flexTotal)
                } else {
                    columnWidths[col] = remainingWidth / CGFloat(flexibleCols.count)
                }
            }
        }

        // Convert to multipliers; last column fills remaining space.
        let totalAssigned = columnWidths.reduce(0, +)
        let ratios: [CGFloat] = columnWidths.map {
            totalAssigned > 0 ? $0 / totalAssigned : 1 / CGFloat(columnCount)
        }

        let columnWidthsPx = ratios.map { $0 * availableWidth }

        // MARK: - Cell factory

        func makeCellView(blocks: [ContentBlock], columnWidth: CGFloat, bold: Bool) -> UIView {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let innerWidth = columnWidth - cellPaddingH * 2
            let cellConfig = NativeRenderConfig(
                baseFont: bold ? config.baseFont.withTraits(.traitBold) : config.baseFont,
                baseColor: config.baseColor,
                linkColor: config.linkColor,
                codeFont: config.codeFont,
                codeBackgroundColor: config.codeBackgroundColor,
                contentWidth: innerWidth,
                baseURL: config.baseURL,
                postId: config.postId,
                galleryImageURLs: config.galleryImageURLs,
                topicTagNames: config.topicTagNames,
                topicCategoryPresentation: config.topicCategoryPresentation
            )

            // Rescale images to fill cell width (TappableImageContainer uses 690px reference)
            let scaledBlocks = Self.scaleImagesForCell(blocks)

            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false

            let views = NativeContentRenderer.renderBlocks(scaledBlocks, config: cellConfig, delegate: delegate)
            for view in views {
                stack.addArrangedSubview(view)
            }

            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: cellPaddingV),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: cellPaddingH),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -cellPaddingH),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -cellPaddingV),
            ])

            return container
        }

        func makeSeparator() -> UIView {
            let sep = UIView()
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.backgroundColor = separatorColor
            sep.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
            return sep
        }

        // MARK: - Assemble table

        let tableStack = UIStackView()
        tableStack.axis = .vertical
        tableStack.spacing = 0
        tableStack.translatesAutoresizingMaskIntoConstraints = false

        for (rowIndex, row) in allRows.enumerated() {
            let bold = isHeaderRow[rowIndex]

            let cells: [UIView] = (0..<columnCount).map { col in
                let cellBlocks = col < row.count ? row[col] : []
                return makeCellView(blocks: cellBlocks, columnWidth: columnWidthsPx[col], bold: bold)
            }

            let rowView = UIView()
            rowView.translatesAutoresizingMaskIntoConstraints = false

            for (col, cell) in cells.enumerated() {
                rowView.addSubview(cell)

                cell.topAnchor.constraint(equalTo: rowView.topAnchor).isActive = true
                cell.bottomAnchor.constraint(equalTo: rowView.bottomAnchor).isActive = true

                if col == 0 {
                    cell.leadingAnchor.constraint(equalTo: rowView.leadingAnchor).isActive = true
                } else {
                    cell.leadingAnchor.constraint(equalTo: cells[col - 1].trailingAnchor).isActive = true
                }

                if col < columnCount - 1 {
                    cell.widthAnchor.constraint(equalTo: rowView.widthAnchor, multiplier: ratios[col]).isActive = true
                } else {
                    cell.trailingAnchor.constraint(equalTo: rowView.trailingAnchor).isActive = true
                }
            }

            if bold {
                rowView.backgroundColor = TopicDetailContentStyle.mutedBackground
            }

            tableStack.addArrangedSubview(rowView)

            if rowIndex < allRows.count - 1 {
                tableStack.addArrangedSubview(makeSeparator())
            }
        }

        // MARK: - Bordered container

        let borderedContainer = UIView()
        borderedContainer.translatesAutoresizingMaskIntoConstraints = false
        TopicDetailContentStyle.applySurface(
            to: borderedContainer,
            backgroundColor: TopicDetailContentStyle.cardBackground,
            cornerRadius: 14,
            borderAlpha: 0.28
        )
        borderedContainer.clipsToBounds = true

        borderedContainer.addSubview(tableStack)
        NSLayoutConstraint.activate([
            tableStack.topAnchor.constraint(equalTo: borderedContainer.topAnchor),
            tableStack.leadingAnchor.constraint(equalTo: borderedContainer.leadingAnchor),
            tableStack.trailingAnchor.constraint(equalTo: borderedContainer.trailingAnchor),
            tableStack.bottomAnchor.constraint(equalTo: borderedContainer.bottomAnchor),
        ])

        return borderedContainer
    }

    // MARK: - Image Scaling

    /// Rescale image dimensions to 690px reference width so TappableImageContainer
    /// renders them at full cell width. Recurses into spoiler/blockquote containers.
    private static func scaleImagesForCell(_ blocks: [ContentBlock]) -> [ContentBlock] {
        blocks.map { block in
            switch block {
            case .image(let src, let alt, let w, let h, let href):
                if let w, let h, w > 0 {
                    let scaled = Int(690.0 * CGFloat(h) / CGFloat(w))
                    return .image(src: src, alt: alt, width: 690, height: scaled, href: href)
                }
                return block
            case .spoiler(let inner):
                return .spoiler(blocks: scaleImagesForCell(inner))
            case .blockquote(let inner):
                return .blockquote(blocks: scaleImagesForCell(inner))
            case .details(let summary, let inner):
                return .details(summary: summary, content: scaleImagesForCell(inner))
            case .policy(let policy):
                return .policy(PolicyBlock(
                    acceptLabel: policy.acceptLabel,
                    revokeLabel: policy.revokeLabel,
                    version: policy.version,
                    groups: policy.groups,
                    accepted: policy.accepted,
                    content: scaleImagesForCell(policy.content)
                ))
            default:
                return block
            }
        }
    }

    // MARK: - Width Estimation

    /// Recursively estimate natural content width from blocks (for column sizing).
    private static func estimateNaturalWidth(of blocks: [ContentBlock], config: NativeRenderConfig) -> CGFloat {
        var maxWidth: CGFloat = 0
        for block in blocks {
            let width: CGFloat
            switch block {
            case .paragraph(let inlines):
                let attr = inlines.attributedString(config: config.attributedStringConfig)
                width = ceil(attr.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                ).width)
            case .heading(_, let inlines):
                let boldConfig = AttributedStringConfig(
                    baseFont: config.baseFont.withTraits(.traitBold),
                    baseColor: config.baseColor,
                    linkColor: config.linkColor,
                    codeFont: config.codeFont,
                    codeBackgroundColor: config.codeBackgroundColor
                )
                let attr = inlines.attributedString(config: boldConfig)
                width = ceil(attr.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    context: nil
                ).width)
            case .image(_, _, let w, _, _):
                width = CGFloat(w ?? 100)
            case .spoiler(let inner):
                width = estimateNaturalWidth(of: inner, config: config)
            case .blockquote(let inner):
                width = estimateNaturalWidth(of: inner, config: config) + 16
            default:
                width = 80
            }
            maxWidth = max(maxWidth, width)
        }
        return maxWidth
    }
}

// MARK: - UIFont + Traits Helper

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits)) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
