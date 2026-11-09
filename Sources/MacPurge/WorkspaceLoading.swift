import SwiftUI

/// Matches the content being loaded and exposes a single status to assistive technologies.
struct WorkspaceSkeleton: View {
  enum Layout {
    case table, applications, inventory, detailInventory, categories
  }

  let layout: Layout
  let message: String
  var rows = 5
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dimmed = false

  var body: some View {
    Group {
      switch layout {
      case .table, .applications: table
      case .categories: categories
      case .inventory, .detailInventory:
        InventoryList(Array(0..<rows), id: \.self, borderless: layout == .detailInventory) { index in
          inventoryRow(index)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .opacity(dimmed && !reduceMotion ? 0.68 : 1)
    .allowsHitTesting(false)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ReviewLanguage.text(message))
    .task(id: reduceMotion) {
      dimmed = false
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) { dimmed = true }
    }
  }

  private var table: some View {
    VStack(spacing: 4) {
      HStack(spacing: 18) {
        bar(width: 74, height: 8).frame(maxWidth: .infinity, alignment: .leading)
        bar(width: 62, height: 8)
        bar(width: 50, height: 8)
        bar(width: 42, height: 8)
      }
      .padding(.horizontal, InventoryLayout.horizontalPadding)
      .frame(height: 24)
      Divider().padding(.bottom, 3)
      ForEach(0..<rows, id: \.self) { index in
        HStack(spacing: 14) {
          if layout == .applications {
            block(width: 22, height: 22, radius: 6)
            labels(index, gap: 5)
          } else {
            bar(width: titleWidth(index), height: 9).frame(maxWidth: .infinity, alignment: .leading)
          }
          bar(width: 56, height: 8)
          bar(width: 45, height: 8)
          bar(width: 52, height: 8)
        }
        .padding(.horizontal, InventoryLayout.horizontalPadding)
        .frame(height: layout == .applications ? 38 : 26)
        .background(.primary.opacity(0.025), in: .rect(cornerRadius: 7))
      }
    }
  }

  private func inventoryRow(_ index: Int) -> some View {
    HStack(spacing: InventoryLayout.controlSpacing) {
      block(width: 12, height: 12, radius: 3)
        .frame(width: InventoryLayout.selectionWidth)
      Color.clear.frame(width: InventoryLayout.disclosureWidth, height: 1)
      labels(index, gap: 7)
      bar(width: 55, height: 8)
      Color.clear.frame(width: 2 * InventoryLayout.actionWidth + InventoryLayout.controlSpacing, height: 1)
    }
    .frame(minHeight: 30)
    .padding(.horizontal, InventoryLayout.horizontalPadding)
    .padding(.vertical, InventoryLayout.verticalPadding)
    .inventoryRowCard(hovered: false)
  }

  private var categories: some View {
    VStack(spacing: 0) {
      ForEach(0..<rows, id: \.self) { index in
        if index > 0 { Divider().padding(.horizontal, ListCardLayout.horizontalPadding) }
        HStack(spacing: 14) {
          block(width: 32, height: 32, radius: 9)
          labels(index, gap: 6)
          bar(width: 62, height: 10)
        }
        .padding(.horizontal, ListCardLayout.horizontalPadding)
        .padding(.vertical, 12)
      }
    }
    .listCardSurface(hovered: false)
  }

  private func labels(_ index: Int, gap: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: gap) {
      bar(width: titleWidth(index), height: 10)
      bar(width: [250, 215, 278][index % 3], height: 7)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func titleWidth(_ index: Int) -> CGFloat { [154, 178, 126][index % 3] }

  private func bar(width: CGFloat, height: CGFloat) -> some View {
    Capsule().fill(.primary.opacity(0.13)).frame(maxWidth: width).frame(height: height)
  }

  private func block(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: radius).fill(.primary.opacity(0.13))
      .frame(width: width, height: height)
  }
}

struct WorkspaceActivityIndicator: View {
  var label: String? = nil

  var body: some View {
    ProgressView()
      .controlSize(.small)
      .accessibilityLabel(label.map(ReviewLanguage.text) ?? "")
      .accessibilityHidden(label == nil)
  }
}
