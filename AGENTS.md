# MacPurge interface rules

## Content lists

- Use the shared components in `Sources/MacPurge/InventoryRow.swift` for content lists on Overview, Project folders, Space plan, Activity, and in review sheets. The visual reference is Overview's **Cleanup by category** list. Storage retains its separate native table and category index, as described below.
- `InventoryList` supplies the enclosing `Surface`, 4 pt horizontal insets, lazy rows and separators. `InventoryHover` supplies the 4 pt vertical inset. Together they leave equal clearance on all four edges. Do not add vertical padding to the list container, which would double the top and bottom gaps. Use `InventoryRows` for nested lists, without another enclosing card. Do not introduce per-screen tables, striped backgrounds or custom row spacing.
- `InventorySeparator` spans the full available row width. Do not inset separators to the title, icon or checkbox column. Nested lists use their full available width within the existing hierarchy indent.
- `InventoryDisclosure` supplies the full-width clickable group header and group selection. `InventoryGroupHeader` supplies its icon, title, badges and amount. Clicking the header expands/collapses or opens the category. Checkboxes and trailing actions remain independent.
- `InventoryMeasuredRow` is the standard cleanable item, including its expandable `InventoryItemDetails`. `InventoryRow` is its lower-level control row. `InventoryReadout` displays informational items, history and restore actions with the same geometry.
- Keep 12 pt of vertical content padding, 7 pt horizontal content padding, an 18 pt leading checkbox slot, a 12 pt disclosure slot, a scaled 108 pt trailing amount column, and 26 pt action slots. Read dimensions from `InventoryLayout` and `InventoryAmount`, rather than duplicating them in screens.
- Reserve trailing folder and action slots to keep amount columns aligned. Informational rows start with their actual icon and must not reserve empty checkbox or disclosure columns. Group headers reserve a checkbox column only when they display that control. Within selectable file lists, unavailable rows retain the checkbox slot to align with their siblings. Use the shared 6 pt control spacing and reserve both trailing action slots in group headers. Amounts align at the same x coordinate in headers, file rows and nested readouts. Nested content adds only the shared 29 pt leading indent, without extra trailing or bottom padding. Badges precede the amount. Amounts align right and use monospaced digits. Long titles truncate in the middle. Descriptions use secondary caption text and at most two lines.
- Use the shared surface radius and the derived row radius. Hover is subtle and transient, with equal clearance from separators and the card border. Pointer exit clears the highlight. Expansion and checkbox selection must not leave a selected row background or a focus border.
- Folder actions appear on hover or keyboard focus and open the recorded location in Finder. Icon-only actions must have tooltips and accessible names. An unavailable cleanup operation uses its explanatory info action.
- Categories and their children always sort by the actual displayed byte amount, largest first, with stable ID tie-breaking. Apply sorting before preview limits. Unknown sizes go last. The Storage **All items** view may offer explicit size/name/date sorting, independently of category ordering.
- Expanded metadata, runtime devices and folder breakdowns use the same nested row geometry. Information-only rows never fabricate a cleanup operation or selectability. Preserve paths, risk explanations, dates, partial measurements, file ages, cleanup boundaries and existing confirmation requirements.
- Retain lazy rendering for full inventories. UI layout must not enumerate files, read directory sizes or start a new scan.

The navigation sidebar, charts, form controls and explanatory prose retain their native roles.

## Cleanup estimates

- Cleanup totals use `CleanupAction.bytes`, the estimated allocated space released after emptying Trash, excluding external hard links. Share selection and totals through `LiveScan.safeMoves` and `LiveScan.cleanupBytes`; fresh previews use `TrashPlan.reclaimableBytes`. Keep `ReportItem.bytes` and `CacheSnapshot.bytes` for measured and moved file sizes, never as recovered-space totals.

## Storage

- Keep the native SwiftUI `Table` with Item, Label, Size, Change, Modified and Action columns. Temporary files retain their recent/older size columns. Do not replace these tables with expandable cleanup cards.
- Keep Storage's separate category index with icon tiles, totals and safety bars. Its category rows open the item table.
- Place checkboxes at the beginning of the Item cell, with a reserved slot for unavailable items. Numeric headers and values align right. Action icons use a fixed column and explain unavailable actions through their tooltip/popover, without inline explanation text.
- Respect the available viewport below the toolbar and filters. Native table scrolling handles longer lists. Preserve native selection, keyboard navigation, column resizing, sorting in All items, and double-click details.
- Category tables always show largest items first with stable ties. Keep filters, hidden-selection counts, last measurements during rescans, and scan progress.
- Storage inspector breakdowns may reuse the common nested rows. Storage's native table selection and row backgrounds are an intentional exception to the cleanup-list hover rules.
